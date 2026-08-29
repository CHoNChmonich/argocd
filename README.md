# k8s pet-project: мини-магазин из трёх микросервисов

Учебный проект для отработки Kubernetes (Ingress, LoadBalancer, HPA, VPA, PDB, …) и Helm.
Этап 1 — само приложение и локальный стенд на docker-compose. Этап 2 — сырые k8s-манифесты (удалены после переезда
на чарт; смотреть в git: `git show 59867c4:manifests/21-orders.yaml`, `git ls-tree 59867c4 manifests/`).
Этап 3 — приложение как свой Helm-чарт `charts/shop`.

## Архитектура

```
клиент ──HTTP──▶ orders ──HTTP──▶ inventory
                   │  │              │  │
                   │  └──▶ Postgres ◀┘  └──▶ Redis (cache-aside)
                   │
                   └──▶ RabbitMQ ──▶ notifier ──▶ Redis (последние уведомления)

все сервисы ──OTLP──▶ Jaeger        Prometheus ──scrape──▶ /metrics всех сервисов
```

| Сервис    | Порт (host) | Что делает | Зависимости |
|-----------|-------------|------------|-------------|
| orders    | 8081 | `POST /orders` резервирует товар в inventory, пишет заказ в Postgres, публикует `order.created` в RabbitMQ; `GET /orders/{id}` через Redis-кэш | Postgres, Redis, RabbitMQ, inventory |
| inventory | 8082 | `GET/PUT /items/{sku}`, `POST /items/{sku}/reserve` (атомарное списание, 409 при нехватке) | Postgres, Redis |
| notifier  | 8083 | воркер: читает очередь `notifications`, «шлёт уведомление», хранит последние 100 в Redis; `GET /notifications` | RabbitMQ, Redis |

Общие эндпоинты каждого сервиса (пакет `services/common`):

- `GET /healthz` — liveness, `GET /readyz` — readiness с проверкой зависимостей (503 если что-то упало)
- `GET /info` — hostname/POD_IP/NODE_NAME — видно, какой под ответил
- `GET /burn?seconds=N` — жжёт CPU, нагрузка для HPA/VPA
- `GET /metrics` — Prometheus (стандартные HTTP-метрики + бизнес-метрики: `orders_created_total`, `inventory_reservations_total`, `notifications_processed_total`, `*_cache_requests_total`)
- `GET /docs` — Swagger

Телеметрия: OpenTelemetry-автоинструментация FastAPI, httpx, SQLAlchemy, Redis, aio-pika.
Один трейс проходит orders → inventory → (через заголовки сообщения RabbitMQ) → notifier.
Логи — JSON с `trace_id`/`span_id`.

Все настройки — через переменные окружения (`services/common/settings.py`): `DATABASE_URL`, `REDIS_URL`,
`RABBITMQ_URL`, `INVENTORY_URL`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `SERVICE_NAME`, `LOG_LEVEL`.

## Образы

Один multistage `services/Dockerfile`, три независимых образа — у каждого свой набор зависимостей
(`services/requirements/<service>.txt`), в runtime нет pip/компиляторов, процесс запускается от uid 10001:

```bash
docker build --target orders    -t shop/orders:dev    services
docker build --target inventory -t shop/inventory:dev services
docker build --target notifier  -t shop/notifier:dev  services
```

Стадии: `builder-base` → `builder-<service>` (venv с зависимостями) → `runtime-base` (тонкий, non-root, common/)
→ `<service>` (копирует venv и только свой код).

## Локальный запуск

```bash
docker compose up -d --build
python scripts/load.py -n 30           # создать заказы, погреть кэш
curl localhost:8083/notifications      # что дошло до воркера
```

UI: Jaeger http://localhost:16686 · Prometheus http://localhost:9090 · RabbitMQ http://localhost:15672 (guest/guest)

## Структура

```
services/            приложение: common/, orders/, inventory/, notifier/, Dockerfile
charts/shop/         Helm-чарт приложения (этап 3)
gitops/              Argo CD: bootstrap/root.yaml (app of apps), platform/*.yaml, apps/shop.yaml (этап 4)
infra/values/        наши values к внешним чартам (сами чарты Argo берёт из репозиториев по версии)
cluster/             registry.sh, bootstrap.sh (Argo CD + root), namespaces/ (Namespace с Pod Security)
deploy/local/        конфиги для docker-compose (prometheus)
scripts/             build-images.sh, deploy.sh, load.py
docker-compose.yaml  локальный стенд без k8s
```

## Этап 2: Kubernetes (сырые манифесты)

Кластер — Docker Desktop с kind-провизионером (1 control-plane + 2 worker, k8s 1.31).
Helm 3 — только клиент (в кластере ничего не ставится), установлен через `winget install Helm.Helm`.

```bash
bash cluster/registry.sh         # локальный registry localhost:5001, подключён к нодам kind
bash scripts/build-images.sh     # build + push localhost:5001/shop/{orders,inventory,notifier}:dev
bash scripts/publish-chart.sh    # helm package + push charts/shop -> localhost:5001/charts/shop:<version>
bash cluster/bootstrap.sh        # helm: только Argo CD + root Application; всё остальное Argo поднимает из git
# дальше любое изменение = commit + push; scripts/deploy.sh = lint + push + refresh + ожидание Synced/Healthy
```

### Внешние чарты: из helm/OCI-репозиториев, values — в git

Чарт — это tar.gz с `Chart.yaml + templates/ + values.yaml`, лежит в репозитории чартов автора (классический
helm-репозиторий или OCI-registry). Argo CD тянет его оттуда по версии (`targetRevision` в `gitops/platform/*.yaml`),
а наши переопределения берёт из `infra/values/<chart>.yaml` этого репозитория (multi-source, `$values`).
В git чужого кода нет; обновление компонента = поменять версию в одном файле.

Посмотреть, что внутри чарта: `helm show values <repo>/<chart> --version X` или `bash infra/vendor.sh`
(скачивает в `infra/charts/`, папка в `.gitignore`). На этапах 2-3 чарты лежали в git (vendoring) — история: `git show a060fe5`.

### Зависимости приложения (`cluster/deps.sh`)

| Релиз | Чарт | Образ | Что создаёт |
|---|---|---|---|
| postgresql | bitnami/postgresql 16.7.27 | `bitnamilegacy/postgresql:17.6.0` | StatefulSet `postgresql-0`, PVC 1Gi, Service `postgresql`, Secret с паролями |
| redis | bitnami/redis 20.13.4 (standalone) | `bitnamilegacy/redis:7.4.3` | StatefulSet `redis-master-0`, PVC, Service `redis-master` |
| rabbitmq | bitnami/rabbitmq 16.0.14 | `bitnamilegacy/rabbitmq:4.1.3` | StatefulSet `rabbitmq-0`, PVC, Service `rabbitmq` (amqp 5672, http-stats 15672) |
| jaeger | jaegertracing/jaeger 3.4.1 (all-in-one, memory) | `jaegertracing/all-in-one:1.53.0` | Deployment, Services `jaeger-collector` (OTLP 4317), `jaeger-query` (UI) |

Про образы: Bitnami с 2025 публикует версионные образы только в платный `bitnamisecure`, в `docker.io/bitnami`
остался лишь `:latest`. Для учёбы пинимся на замороженный `bitnamilegacy/*` (без security-обновлений) —
чарт требует `global.security.allowInsecureImages: true` при подмене repository. В проде сейчас берут
операторы (CloudNativePG, RabbitMQ Cluster Operator) либо managed-сервисы.

Имена Service'ов из чартов прописаны в `charts/shop/values.yaml` → `dependencies` (`postgresql`, `redis-master`,
`rabbitmq`) и `config.otelEndpoint` (`jaeger-collector`); пароли приложение берёт из Secret'ов этих релизов
(`existingSecret`/`secretKey`), задаются один раз в `infra/values/*.yaml`.
Все объекты релиза помечены `app.kubernetes.io/managed-by: Helm` и аннотациями `meta.helm.sh/release-*`;
чужие объекты с теми же именами Helm в релиз не примет.

Особенности kind-нод: это контейнеры со своим containerd, образы docker CLI им не видны —
поэтому registry (как в проде). IP из сети kind (172.20.x.x) с хоста недоступны; LoadBalancer-порты
Docker Desktop пробрасывает на `localhost`, NodePort — нет.

При старте приложения падают, пока RabbitMQ/Postgres не готовы, и k8s их перезапускает (RESTARTS 1-2) —
это штатно: crash -> restart с backoff, readiness держит под вне трафика до готовности зависимостей.

Что демонстрировали сырые манифесты (теперь всё это — шаблоны `charts/shop/templates/`):
Namespace + Pod Security `restricted` (остался в `cluster/namespace-shop.yaml`); ConfigMap/Secret через `envFrom`;
Deployment с RollingUpdate, startup/readiness/liveness-пробами, requests/limits, securityContext, downward API;
Service ClusterIP; Ingress host- и path-based с rewrite; HPA/PDB/VPA; ServiceMonitor/PrometheusRule/дашборд.
Справочник по типам Service (LoadBalancer/NodePort/Headless) — `git show 59867c4:manifests/examples/service-types.yaml`.

Проверка:

```bash
curl http://orders.shop.localtest.me/info            # через Ingress (host)
curl http://shop.localtest.me/api/inventory/items    # через Ingress (path + rewrite)
for i in $(seq 6); do curl -s http://orders.shop.localtest.me/info; echo; done   # балансировка между подами
kubectl top pods -n shop                              # metrics-server
python scripts/load.py --orders http://orders.shop.localtest.me -n 20
```

UI: Jaeger http://jaeger.shop.localtest.me · RabbitMQ http://rabbitmq.shop.localtest.me

Единственная точка входа снаружи — Service `ingress-nginx-controller` типа LoadBalancer (порт 80 → `localhost`).
Сервисы приложения — только ClusterIP, наружу публикуются Ingress-правилами. Так же в проде:
один LB на кластер + L7-маршрутизация, прямые LoadBalancer/NodePort на сервисах — исключение для не-HTTP протоколов.

## Этап 2b: масштабирование и устойчивость

Все stateless-поды в нескольких репликах, разложены по нодам через `topologySpreadConstraints`
(`nodeTaintsPolicy: Honor` — иначе control-plane с taint считается доменом с 0 подов и spread ломается):
orders/inventory — HPA 2..6, notifier — 2, ingress-controller — 2 (values чарта: `replicaCount`, `minAvailable`,
`topologySpreadConstraints`). Spread проверяется только при планировании: после rolling-update поды могут
оказаться на одной ноде, `rollout restart` (или descheduler в проде) исправляет.

**HPA** (metrics-server -> `metrics.k8s.io`): под нагрузкой `/burn` orders вырос 2 -> 4 -> 6 за ~30 с,
после снятия — вниз по одному поду в 30 с (`behavior.scaleDown`). `replicas` из Deployment убран —
им владеет HPA, иначе каждый `kubectl apply` спорил бы с ним.

```bash
for i in $(seq 6); do (for j in $(seq 20); do curl -s "http://orders.shop.localtest.me/burn?seconds=4" >/dev/null; done) & done
kubectl -n shop get hpa -w
```

**PDB** ограничивает добровольные прерывания (drain, VPA updater, autoscaler): API Eviction возвращает 429,
drain ждёт и повторяет. Проверка: `kubectl drain desktop-worker2 --ignore-daemonsets --delete-emptydir-data`,
потом `kubectl uncordon desktop-worker2`. Что показал drain:
- поды orders эвакуировались по одному — `Cannot evict pod as it would violate the pod's disruption budget`;
- PDB считает только Ready-поды: пока новые поды не прошли readiness, `ALLOWED DISRUPTIONS = 0` и drain стоит;
- **PVC на local-path привязан к ноде** (`PV nodeAffinity`): postgresql-0 и rabbitmq-0 после эвакуации зависли
  в Pending, пока нода не вернулась — приложение потеряло БД. В проде для stateful нужен сетевой storage
  (CSI, cloud disks) или репликация на уровне приложения (Patroni/CloudNativePG, RabbitMQ quorum queues).
  PDB чартов (`maxUnavailable: 1`) эвакуацию разрешили — при одной реплике это и есть даунтайм.

**VPA** (чарт fairwinds/vpa: recommender + updater + admission-webhook):
```bash
kubectl -n shop get vpa                                    # рекомендации target/lower/upper
kubectl -n shop get vpa orders -o jsonpath='{.status.recommendation}' | python -m json.tool
```
Рекомендации через минуты: CPU 15m против наших requests 100m — мы заложили с запасом. Режим `Initial`
у notifier подставляет рекомендацию новым подам (аннотация `vpaUpdates`); во время drain webhook сам был
эвакуирован и один под создался без правок — `failurePolicy: Ignore`.

## Этап 2c: мониторинг — kube-prometheus-stack

`infra/values/kube-prometheus-stack.yaml`, namespace `monitoring`, ставится **первым** в `bootstrap.sh`: приносит CRD
`ServiceMonitor` / `PodMonitor` / `PrometheusRule`, на которые ссылаются values ingress-nginx и bitnami-чартов.

| Компонент | Роль | URL |
|---|---|---|
| prometheus-operator | из CRD генерирует конфиг Prometheus/Alertmanager | — |
| Prometheus (StatefulSet, PVC 5Gi, retention 3d) | сбор и хранение временных рядов, PromQL | http://prometheus.shop.localtest.me |
| Alertmanager | маршрутизация/группировка алертов | http://alertmanager.shop.localtest.me |
| Grafana (admin/admin) | дашборды; sidecar подхватывает ConfigMap с label `grafana_dashboard=1` | http://grafana.shop.localtest.me |
| kube-state-metrics, node-exporter | состояние объектов k8s, метрики нод | — |

metrics-server при этом остаётся: он — источник для HPA/VPA (`metrics.k8s.io`, только «сейчас»), Prometheus — для людей,
истории и алертов. Единственное пересечение — CPU/RAM подов из cAdvisor.

Что собирается (`Status -> Targets` в Prometheus): наши сервисы (ServiceMonitor `shop-services` по label
`app.kubernetes.io/part-of: shop`), ingress-nginx, postgres-exporter / redis-exporter (sidecar'ы, `metrics.enabled` в values),
rabbitmq_prometheus (`prometheus.return_per_object_metrics = true` — иначе нет метки `queue`), kubelet/cAdvisor, apiserver,
coredns, kube-state-metrics, node-exporter. Control-plane-таргеты (controller-manager, scheduler, etcd, kube-proxy)
выключены — в kind они слушают 127.0.0.1 ноды.

Важное в values: `*SelectorNilUsesHelmValues: false` — иначе Prometheus видит только мониторы с label `release=<релиз>`
и игнорирует чужие (частая причина «ServiceMonitor есть, а таргета нет»).

```bash
kubectl get servicemonitor,prometheusrule -A
curl -s 'http://prometheus.shop.localtest.me/api/v1/query?query=sum by (outcome) (rate(orders_created_total[5m]))'
```

### Логи — Loki + Alloy

`infra/values/loki.yaml` (chart grafana/loki 7.3, режим SingleBinary, PVC 5Gi, retention 72h) и
`infra/values/alloy.yaml` (grafana/alloy 1.12, DaemonSet на всех нодах включая control-plane).
Alloy находит поды своей ноды через API, читает их логи через kubelet (как `kubectl logs`, без hostPath и root),
вешает метки `namespace/pod/container/app/node`, из JSON вытаскивает `level` в structured metadata и шлёт
в `loki-gateway`. Grafana получает datasource Loki и Jaeger (`grafana.additionalDataSources`), у Loki настроен
derived field: `trace_id` в строке лога — ссылка на трейс в Jaeger.

Позиции чтения Alloy хранятся на диске ноды (`hostPath /var/lib/alloy-positions`): с emptyDir после каждого рестарта
агент перечитывал логи с начала, Loki отвергал строки старше часа (`loki_discarded_samples_total{reason="too_far_behind"}`),
а Alloy писал `status=400 dropping data`. Здоровье сбора: `sum(increase(loki_discarded_samples_total[5m]))` должно быть 0,
в логах `ds/alloy` — без `level=error`.

Loki индексирует только метки, не текст: меток должно быть мало и низкой кардинальности (никаких trace_id/user_id
в метках — каждая комбинация = отдельный stream). Поиск: Grafana → Explore → Loki:

```logql
{namespace="shop"}                                              # всё из namespace
{namespace="shop", app="orders"} | json | level="ERROR"          # только ошибки orders
{namespace="shop"} | json | trace_id="d49a9963..."               # все строки одного запроса из всех сервисов
sum by (app) (rate({namespace="shop"} | level="ERROR" [5m]))     # метрика из логов (для алертов)
```

### Трейсы

Jaeger: http://jaeger.shop.localtest.me → Service `orders` → Find Traces. Трейс начинается в **ingress-nginx**
(встроенный OpenTelemetry-модуль контроллера, включён ключами `controller.config.enable-opentelemetry` и
`otlp-collector-host` в `infra/values/ingress-nginx.yaml`), продолжается в orders → inventory и через
заголовки RabbitMQ — в notifier. Контекст между nginx и приложением передаётся заголовком W3C `traceparent`.
По `trace_id` из JSON-лога пода трейс открывается напрямую: `http://jaeger.shop.localtest.me/trace/<trace_id>`.

## Этап 3: приложение как Helm-чарт (`charts/shop`)

```
charts/shop/
├── Chart.yaml              name/version (версия чарта) / appVersion (версия приложения = тег образа по умолчанию)
├── values.yaml             дефолты: image, config, dependencies, serviceDefaults, services{orders,inventory,notifier}, ingress, monitoring
├── values-lab.yaml         переопределения для локального кластера (tag: dev, pullPolicy: Always)
├── templates/
│   ├── _helpers.tpl        именованные шаблоны: labels, selectorLabels, image, serviceValues (deep-merge дефолтов и сервиса)
│   ├── configmap.yaml      несекретный env: LOG_LEVEL, OTEL_*, DB_HOST/PORT/USER, REDIS_HOST, RABBITMQ_HOST/USER
│   ├── deployment.yaml     range по services: ServiceAccount + Deployment + Service на каждый
│   ├── autoscaling.yaml    HPA / PDB / VPA на каждый сервис (по флагам в values)
│   ├── ingress.yaml        host-based <svc>.<domain> + extraHosts + path-based с rewrite
│   ├── monitoring.yaml     ServiceMonitor, PrometheusRule, ConfigMap-дашборд (только если CRD есть: .Capabilities)
│   ├── tests/              helm test: под с curl проверяет /readyz каждого сервиса
│   └── NOTES.txt           что печатается после install
└── files/                  prometheus-rules.yaml, dashboards/shop.json — через .Files.Get, без шаблонизации
```

Ключевые приёмы:
- **один шаблон на N сервисов**: `range $name, $_ := .Values.services`, значения сервиса = `serviceDefaults` ⊕ `services.<name>`
  (`mustMergeOverwrite`); внутри range корень доступен через `$root`;
- **пароли не дублируются**: приложение собирает URL из частей (`DB_HOST` из ConfigMap + `DB_PASSWORD` через
  `secretKeyRef` на Secret, созданный чартом postgresql); в git паролей приложения больше нет;
- **checksum/config** аннотация в поде: изменился ConfigMap → перекат подов;
- **селекторы неизменяемы**: `selectorLabels` без версии чарта, иначе `helm upgrade` упадёт на immutable field;
- `.Capabilities.APIVersions.Has` — CRD-объекты рендерятся только там, где CRD установлены
  (`helm template --api-versions monitoring.coreos.com/v1` для рендера без кластера);
- `replicas` не рендерится, если у сервиса включён HPA.

```bash
helm lint ./charts/shop -f charts/shop/values-lab.yaml
helm template shop ./charts/shop -n shop -f charts/shop/values-lab.yaml | less     # что будет применено
helm upgrade --install shop ./charts/shop -n shop -f charts/shop/values-lab.yaml --wait
helm test shop -n shop --logs
helm history shop -n shop; helm rollback shop 1 -n shop
helm package ./charts/shop -d dist && helm push dist/shop-0.1.0.tgz oci://localhost:5001/charts --plain-http
helm install shop oci://localhost:5001/charts/shop --version 0.1.0 --plain-http -n shop   # установка из registry
```

Грабли, пойманные при переезде: `imagePullPolicy: IfNotPresent` + мутабельный тег `:dev` — нода не подтянула
пересобранный образ, поды стартовали со старым кодом (в лабе `pullPolicy: Always`, в проде — иммутабельные теги);
Helm не принимает объекты, созданные `kubectl apply` с теми же именами — старые манифесты сначала удаляются.

## Этап 4: GitOps — Argo CD

Pull-модель: контроллер в кластере сам клонирует https://github.com/CHoNChmonich/argocd и приводит кластер
к состоянию из git. `helm upgrade`/`kubectl apply` руками больше не делаются (Argo с `selfHeal` откатит за секунды —
`kubectl scale deploy/notifier --replicas=5` вернулся к 2 через 15 с).

```
cluster/bootstrap.sh ──▶ helm template argo-cd (argo/argo-cd 10.4.0 + infra/values/argo-cd.yaml) | kubectl apply
                     ──▶ kubectl apply gitops/bootstrap/  (AppProject bootstrap + root)
root (Application, path gitops/, recurse) ──▶ platform/*.yaml, apps/shop.yaml — по одному Application на компонент
   wave -5  argo-cd               тот же чарт и values: Argo усыновляет себя (self-managing)
   wave -4  AppProject platform, shop; default выхолощен
   wave -3  Secret'ы репозиториев (OCI)
   wave -2  namespaces            cluster/namespaces/*.yaml (plain YAML)
   wave  0  kube-prometheus-stack (CRD для остальных; ServerSideApply — CRD > 262 КБ)
   wave  1  ingress-nginx, metrics-server, vpa
   wave  2  loki, alloy, postgresql, redis, rabbitmq, jaeger
   wave  3  shop                  kind-registry:5000/charts/shop:0.1.0 + values-lab.yaml из git
```

Каждый Application — **multi-source**: источник 1 — чарт из helm/OCI-репозитория (`chart` + `targetRevision`),
источник 2 — наш git как `ref: values`, откуда берётся `$values/infra/values/<x>.yaml`. OCI-registry объявлены
Secret'ами в `gitops/platform/01-repositories.yaml` (`argocd.argoproj.io/secret-type: repository`). Bitnami —
`type: helm` + `enableOCI`; наш `kind-registry` работает по HTTP, а helm-тип умеет только TLS (`insecure` = не проверять
сертификат, `helm pull` без `--plain-http` падает) — поэтому для него **нативный OCI-источник Argo CD 3.x**:
`type: oci`, `url: oci://kind-registry:5000/charts/shop`, `insecureOCIForceHttp: "true"`, а в Application —
`repoURL: oci://…`, `targetRevision: <версия>`, `path: .`. Наш чарт — версионированный артефакт в том же registry, что и образы:
`scripts/publish-chart.sh` → `targetRevision` в `gitops/apps/shop.yaml` → push. Для разработки шаблонов можно
временно указать источник `path: charts/shop` (пример в комментарии файла).
Argo не использует `helm install`: он делает `helm template` и применяет результат сам (`helm list` релизов не покажет).

UI: http://argocd.shop.localtest.me (admin, пароль: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).

Добавить компонент = файл в `gitops/platform/` (репозиторий + chart + версия) + values в `infra/values/` + push.
Выкатить новую версию приложения = `build-images.sh` (новый тег) → тег в values, `version` в `Chart.yaml` →
`publish-chart.sh` → `targetRevision` в `gitops/apps/shop.yaml` → push.

### AppProject — границы (`gitops/platform/00-projects.yaml`, `gitops/bootstrap/project.yaml`)

Встроенный проект `default` разрешает всё везде, а Argo работает под cluster-admin → доступ в git = root в кластере.
Проекты режут по владельцу, контроллер проверяет каждый sync и отклоняет нарушение
(`destination ... do not match any of the allowed destinations in project`):

| Проект | Application'ы | sourceRepos | destinations | cluster-scoped |
|---|---|---|---|---|
| `bootstrap` | root | наш git | только ns `argocd`, только Application/AppProject/Secret | нет |
| `platform` | всё из `gitops/platform/` | наш git + перечисленные helm/OCI-репо | любой ns | да (CRD, ClusterRole, Namespace) |
| `shop` | `gitops/apps/shop.yaml` | наш git + `oci://kind-registry:5000/charts/shop` | только ns `shop`; ResourceQuota/LimitRange запрещены | нет |
| `default` | — | пусто | пусто | нет |

`bootstrap`-проект лежит рядом с root и применяется руками: root не может создать проект, на который сам ссылается
(Application без существующего проекта не синхронизируется). `default` не удаляем (Argo пересоздаст), а обнуляем из git.
Новый источник чартов = правка `sourceRepos` в PR — осознанное решение, а не побочный эффект.

### Argo управляет собой (`gitops/platform/00-argo-cd.yaml`)

Bootstrap только рендерит чарт (`helm template | kubectl apply --server-side`) — helm-релиза нет, второго «владельца»
не остаётся. Дальше Application `argo-cd` с тем же чартом и `infra/values/argo-cd.yaml` усыновляет объекты
(spec совпадает → Synced без рестартов) и любое изменение values/версии идёт через git — проверено: `statusbadge.enabled`
в values → через 30 с в `argocd-cm`. Обновление самого себя штатно: sync записан в статусе Application, перезапущенный
controller его продолжает. Особенности:
- `ignoreDifferences` + `RespectIgnoreDifferences=true` на `argocd-secret` — страховка, а не необходимость: чарт
  рендерит Secret без блока `data`, `admin.password`/`server.secretkey` дописывает сам Argo, и т.к. Argo сравнивает
  только поля из desired, без правила diff тоже пустой (проверено: сняли правило и автосинк — Synced, ключи целы).
  Нужно оно, если задать `configs.secret.*` в values — тогда `data` рендерится и смена пароля через UI даёт OutOfSync;
- `ServerSideApply=true` — CRD Application/ApplicationSet больше лимита client-side annotation;
- без `resources-finalizer`: удаление Application не должно сносить сам Argo;
- Job `argocd-redis-secret-init` с helm-hook'ами: под kubectl — обычный Job, под Argo — PreSync-хук (идемпотентен);
- известные «сироты» в `argocd` (`argocd-initial-admin-secret`, `argocd-redis`, ручные `bootstrap`/`root`) —
  в `orphanedResources.ignore` проекта `platform`.

**cluster-admin у контроллера — норма**: его права не могут быть уже суммы того, что через него деплоят
(CRD, ClusterRole, любые namespace). Ограничивают не контроллер, а людей и токены: AppProject — что можно деплоить,
`configs.rbac` в values (`argocd-rbac-cm`) — кто что может: `policy.default: role:readonly`, `role:platform-admin`
(всё), `role:shop-dev` (get/sync/action/logs только в проекте `shop`, без правки Application, без exec). Привязка
ролей к людям появится с SSO (dex); до этого один `admin`, который RBAC обходит. Альтернативы для других топологий —
namespaced-install (`createClusterRoles: false`) и management-кластер с урезанным SA на каждый целевой кластер.

Bootstrap с нуля проверен дважды (Docker Desktop пересоздаёт kind-кластер при своём перезапуске — данные PVC
теряются, registry с `--restart=always` переживает): `registry.sh` → `bootstrap.sh` → 14/14 Synced/Healthy за ~5 мин.

Что поймали при переезде:
- репозиторий был приватным — Argo не может клонировать анонимно (`authentication required: Repository not found`);
  сделали публичным (альтернатива — Secret с токеном, `argocd.argoproj.io/secret-type: repository`);
- liveness `repo-server` (`/healthz?full=true`, timeout 1s) убивал под на WSL2 — таймауты проб подняты в values;
- bitnami-чарты «запоминают» случайные пароли через `lookup`, а Argo рендерит без доступа к кластеру —
  пароли (в т.ч. `postgresPassword`) заданы явно, иначе менялись бы при каждом sync;
- `resourceTrackingMethod: annotation` — иначе Argo перезаписывает label `app.kubernetes.io/instance`, на который
  завязаны селекторы bitnami-чартов.

## Этап 5: секреты, webhook, SSO

### Sealed Secrets — пароли не в values (`gitops/platform/05-sealed-secrets.yaml`, `06-secrets.yaml`, `secrets/`)

Раньше пароли лежали открытым текстом в `infra/values/*.yaml` публичного репозитория. Теперь:

```
scripts/seal.sh <ns> <name> key=value ...   ──kubeseal (публичный ключ из кластера)──▶  secrets/<ns>/<name>.yaml (SealedSecret)
Argo (Application secrets, wave 0)  ──▶  SealedSecret в кластере  ──контроллер (приватный ключ)──▶  Secret <name>
чарты читают Secret по имени: auth.existingSecret / existingPasswordSecret / grafana.admin.existingSecret
```

- Шифрование асимметричное (RSA-OAEP + AES-GCM), привязано к namespace+имени (scope `strict`): SealedSecret нельзя
  перенести в другой namespace и расшифровать нигде, кроме этого кластера. Поэтому его безопасно коммитить.
- Имена/ключи Secret'ов те же, что раньше создавали чарты (`postgresql`: `password`/`postgres-password`,
  `redis`: `redis-password`, `rabbitmq`: `rabbitmq-password`/`rabbitmq-erlang-cookie`, `grafana-admin`,
  `argocd-secret`) — чарт shop (`existingSecret` в values) не менялся.
- Все пароли ротированы (старые есть в истории git). PVC Postgres/RabbitMQ пересозданы: данные инициализированы
  старыми кредами. Ротация в проде = новый SealedSecret + перезапуск потребителей (env читается при старте пода).
- `argocd-secret` теперь целиком из git (`configs.secret.createSecret: false`): bcrypt-хэш admin, `server.secretkey`
  (подпись JWT), `webhook.github.secret`, позже `dex.github.*`. `ignoreDifferences` на него больше не нужен.
- **Ключ контроллера — единственное, чего нет в git.** `cluster/sealed-secrets-key.sh` кладёт его в `cluster/secrets/`
  (в `.gitignore`), `cluster/bootstrap.sh` восстанавливает **до** старта контроллера — иначе после пересоздания
  кластера все SealedSecret'ы бесполезны и всё придётся перезапечатывать. В проде бэкап ключа — в Vault/KMS.
  `keyrenewperiod: "0"` — без автоматической ротации ключа (иначе бэкап надо обновлять каждые 30 дней).
- Миграция без простоя: с существующих Secret'ов снята tracking-аннотация Argo (чтобы prune их не удалил) и добавлена
  `sealedsecrets.bitnami.com/managed: "true"` — контроллер перезаписал данные на месте вместо ошибки «already exists».
- `.gitignore`: комментарий в одной строке с паттерном — часть паттерна; `infra/charts/   # ...` не работал.

Альтернатива — External Secrets Operator: секреты живут в Vault/AWS SM/GCP SM, в git только `ExternalSecret`
(ссылка «возьми ключ X из хранилища»). Правильнее для компаний с централизованным хранилищем; Sealed Secrets —
когда хранилища нет и нужен self-contained GitOps.

### Webhook вместо поллинга

Argo принимает `POST /api/webhook` (GitHub/GitLab/Bitbucket/Gitea) и делает refresh всем Application'ам, чьи источники
указывают на репозиторий из payload. Подпись `X-Hub-Signature-256` проверяется HMAC-ключом `webhook.github.secret`
из `argocd-secret` (проверено: невалидная подпись → `400 HMAC verification failed`, валидная → 200 и refresh).
Ключ читается при старте `argocd-server` — после смены секрета нужен рестарт. Поллинг (`timeout.reconciliation`)
остаётся резервом (в проде — default 3m, у нас 60s, потому что GitHub не достаёт до localhost). Для реального
webhook нужен публичный URL: GitHub → Settings → Webhooks → `https://<argo>/api/webhook`, content type json,
secret = `webhook.github.secret`, событие push. Локально — туннель (cloudflared/ngrok) на `argocd.shop.localtest.me`.

## Дальше

1. NetworkPolicy, ResourceQuota/LimitRange, Job/CronJob (миграции как helm hook).
2. RBAC для людей (k8s), cert-manager + TLS. Argo: SSO через Dex/GitHub (+ отключить admin), ApplicationSet/окружения
   (см. заметки в чате: envs/ папками, git files generator), notifications, Rollouts.
3. HPA по метрикам Prometheus (prometheus-adapter) и KEDA для notifier по длине очереди.
