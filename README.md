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
cluster/             kind-config.yaml + kind-up.sh (кластер), registry.sh, bootstrap.sh (Calico + Argo CD + root),
                     namespaces/ (Namespace с Pod Security), network/ (NetworkPolicy, этап 6), vault-init.sh
deploy/local/        конфиги для docker-compose (prometheus)
scripts/             build-images.sh, deploy.sh, load.py
docker-compose.yaml  локальный стенд без k8s
```

## Этап 2: Kubernetes (сырые манифесты)

Кластер — kind (1 control-plane + 2 worker, k8s 1.34), описан декларативно в `cluster/kind-config.yaml`
(до этапа 6 — кластер провизионера Docker Desktop: у него нет настроек CNI, и он пересоздаётся при каждом
перезапуске Docker; Kubernetes в Docker Desktop теперь выключен). `winget install Kubernetes.kind Helm.Helm` —
оба только клиенты на хосте.

```bash
bash cluster/kind-up.sh          # kind create cluster --config cluster/kind-config.yaml + registry.sh
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
поэтому registry (как в проде). IP из сети kind (172.20.x.x) с хоста недоступны, LoadBalancer реализовать
некому — ingress-nginx на фиксированных NodePort 30080/30443, а `extraPortMappings` в kind-config пробрасывает
в них 80/443 хоста.

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

### Vault + External Secrets Operator — пароли не в git (`05-vault.yaml`, `05-external-secrets.yaml`, `06-secrets.yaml`, `secrets/`)

Раньше пароли лежали открытым текстом в `infra/values/*.yaml` публичного репозитория (промежуточно — Sealed Secrets,
заменён: значения всё равно жили в git, пусть и зашифрованными; ротация = коммит; нет аудита и динамических кредов).

```
cluster/vault-init.sh ──▶ Vault (KV v2 secret/<ns>/<name>: значения)           <- единственное, что не из git
git: secrets/cluster-secret-store.yaml (как ходить в Vault) + secrets/<ns>/<name>.yaml (ExternalSecret: что принести)
        │ Argo (Application secrets, wave 0)
        ▼
ESO ──(SA-токен → Vault Kubernetes auth, роль eso, политика eso-read)──▶ Vault ──▶ Secret <name> в кластере
чарты читают Secret по имени: auth.existingSecret / existingPasswordSecret / grafana.admin.existingSecret
```

- **Vault** (`hashicorp/vault 0.34.1`, single-node, storage raft на PVC, UI http://vault.shop.localtest.me):
  хранит секреты зашифрованными, после каждого рестарта **запечатан** (sealed) — `cluster/vault-init.sh` распечатывает
  unseal-ключом из `cluster/secrets/vault-init.json` (в `.gitignore`; прод — auto-unseal через KMS, 3-5 нод raft,
  root-токен отзывают после настройки). PSA restricted: `disable_mlock = true` вместо capability IPC_LOCK, `drop ALL` + seccomp.
- **ESO** (`external-secrets 2.10.0`): сам ничего не хранит. `ClusterSecretStore vault` — адрес, `path: secret`, KV v2,
  auth Kubernetes: ESO предъявляет токен своего ServiceAccount `external-secrets`, Vault проверяет его через TokenReview
  (ClusterRoleBinding `authDelegator` из чарта) и выдаёт токен роли `eso` с политикой `eso-read` (только чтение
  `secret/data/*`). Статических кредов Vault в кластере нет. `ExternalSecret` — `dataFrom.extract: {key: shop/postgresql}`:
  все ключи из Vault → ключи Secret как есть, `target.name` = имя, которое ждёт чарт, `refreshInterval: 1h`.
- `vault-init.sh` идемпотентен: init (один раз) → unseal → KV/auth/policy/role → seed случайных паролей **только для
  отсутствующих** путей (bcrypt admin Argo считает `argocd account bcrypt` в поде). `bootstrap.sh` вызывает его после root.
  Ловушка: `cmd | grep -q` под `set -o pipefail` — grep закрывает пайп, kubectl получает SIGPIPE, условие ложно.
- **Ротация без коммита**: `vault kv put secret/monitoring/grafana-admin admin-password=...` → ESO обновляет Secret за
  `refreshInterval` (или сразу: `kubectl annotate externalsecret ... force-sync=$(date +%s)`). Проверено на Grafana.
  Потребители, читающие секрет через env, увидят его после рестарта пода; через volume — kubelet обновит файл сам.
- `argocd-secret` тоже из Vault (`configs.secret.createSecret: false`): bcrypt admin, `server.secretkey`, `webhook.github.secret`.
- Миграция без простоя: с Secret'ов сняты `ownerReferences` SealedSecret'ов (иначе GC удалил бы их вместе с CRD),
  текущие значения записаны в Vault поверх seed, ESO стал владельцем — данные байт-в-байт те же, PVC не пересоздавались.
  Остатки Sealed Secrets (namespace с `prune: false`, CRD с `keep`) удалены руками.

**Доступ людей — не root.** `vault-init.sh` создаёт политику `platform-admin` (всё в `secret/*`, без администрирования
Vault) и пользователя `artem` (auth-метод `userpass`). Вход выдаёт личный токен с TTL 8h (max 24h), каждое действие в
аудите под `userpass-artem`; root-токен — только для bootstrap (прод: отозвать, людям — OIDC и группы → политики).
```
vault login -method=userpass username=artem      # CLI на машине: VAULT_ADDR=http://vault.shop.localtest.me
kubectl -n vault exec -it vault-0 -- vault login -method=userpass username=artem   # или внутри пода
```
UI: метод Username. Сменить пароль: `vault write auth/userpass/users/artem password=NEW`.

**Ежедневная работа** (`scripts/vault.sh` = обёртка над `kubectl exec vault-0 -- vault ...`; в проде — CLI на машине с личным токеном):

| Задача | Команда |
|---|---|
| посмотреть, что есть | `scripts/vault.sh kv list secret/shop` |
| прочитать | `scripts/vault.sh kv get secret/shop/redis` (`-field=redis-password` — одно значение) |
| что реально в кластере | `kubectl -n shop get secret redis -o jsonpath='{.data.redis-password}' \| base64 -d` |
| добавить секрет | `kv put secret/shop/x k=v` → `secrets/shop/x.yaml` (ExternalSecret) → push; чарт: `existingSecret: x`; строка `seed` в `vault-init.sh` |
| изменить один ключ | `scripts/vault.sh kv patch secret/shop/postgresql password=NEW` (`put` перезаписывает **все** ключи) |
| применить сразу | `kubectl -n shop annotate externalsecret postgresql force-sync=$(date +%s)` (иначе ≤ refreshInterval 1h) |
| донести до потребителя | env-потребители: `kubectl rollout restart`; БД: пароль ещё и в данных — bitnami не меняет его на существующем PVC |
| история / откат | `kv metadata get`, `kv get -version=N`, `kv rollback -version=N` (KV v2 хранит 10 версий) |
| удалить | `kv delete` (soft, версия помечена), `kv destroy -versions=N`, `kv metadata delete` (всё); ExternalSecret из git → prune → Secret удалит GC |
| статус доставки | `kubectl get externalsecret -A` (`SecretSynced`/`SecretSyncedError`), `kubectl get clustersecretstore` |

Что даёт Vault сверх «секрет в git»: аудит каждого чтения, политики per-consumer, TTL токенов, **динамические секреты**
(движок `database` выдаёт временных пользователей Postgres) — следующий шаг этого этапа.

### Webhook вместо поллинга

Argo принимает `POST /api/webhook` (GitHub/GitLab/Bitbucket/Gitea) и делает refresh всем Application'ам, чьи источники
указывают на репозиторий из payload. Подпись `X-Hub-Signature-256` проверяется HMAC-ключом `webhook.github.secret`
из `argocd-secret` (проверено: невалидная подпись → `400 HMAC verification failed`, валидная → 200 и refresh).
Ключ читается при старте `argocd-server` — после смены секрета нужен рестарт. Поллинг (`timeout.reconciliation`)
остаётся резервом (в проде — default 3m, у нас 60s, потому что GitHub не достаёт до localhost). Для реального
webhook нужен публичный URL: GitHub → Settings → Webhooks → `https://<argo>/api/webhook`, content type json,
secret = `webhook.github.secret`, событие push. Локально — туннель (cloudflared/ngrok) на `argocd.shop.localtest.me`.

## Этап 6: сеть — Calico и NetworkPolicy (`cluster/kind-config.yaml`, `00-calico.yaml`, `01-network.yaml`, `cluster/network/`)

Проблема: kindnet (CNI по умолчанию в kind) не исполняет NetworkPolicy — объекты создаются, а трафик ходит. Любой
под мог открыть Postgres, Vault или интернет. Решение — свой CNI. Cilium (eBPF, Hubble) и Calico делают одно и то же
для стандартных политик; выбран Calico как более простой и предсказуемый на kind под WSL2.

Как ставится. Кластер создан с `disableDefaultCNI: true` — ноды NotReady, пока нет CNI, поэтому Calico идёт первым
шагом `bootstrap.sh`, той же схемой, что Argo: `helm template projectcalico/tigera-operator --no-hooks | kubectl apply`
(`--no-hooks`: в чарте Job с hook `pre-delete` — деинсталляция, kubectl запустил бы его как обычный ресурс). Чарт ставит
только оператор Tigera; CRD оператор создаёт сам при старте, поэтому CR `Installation`/`Goldmane`/`Whisker` применяются
вторым проходом (Argo — `retry`). Дальше всем владеет Application `calico` (wave -6). Values `infra/values/calico.yaml`:
пул 10.244.0.0/16 = `podSubnet` kind, VXLAN без BGP (ноды — контейнеры в одной L2-сети, IPIP-модуль в WSL2 не нужен),
apiserver Calico (`projectcalico.org/v3` с валидацией), Goldmane + Whisker — flow-логи и UI http://whisker.shop.localtest.me:
каждое соединение, allow/deny и имя политики (то, что у Cilium делает Hubble).

Политики — `cluster/network/`, Application `network` (wave -1, после namespaces). Два уровня:
- `global/` — Calico `GlobalNetworkPolicy`, кластерные: `default-deny` (Ingress+Egress для всех прикладных namespace,
  order 10000 — проверяется последним), `allow-dns` (всем — к CoreDNS:53), `allow-apiserver` (к :6443 — только argocd,
  monitoring, ingress-nginx, vault, external-secrets, vpa; приложению apiserver не нужен). Системные namespace
  (kube-system, calico-*, tigera-operator, local-path-storage) из deny исключены.
- `<ns>/` — стандартные `NetworkPolicy` (order 1000, переносимы на любой CNI): что разрешено. shop — по сервисам:
  приложения (`part-of: shop`) принимают 8000 от ingress-nginx/друг друга/Prometheus, ходят только в postgresql:5432,
  redis:6379, rabbitmq:5672, jaeger:4317/4318 и друг к другу; БД принимают только от приложений и exporter-порты от
  monitoring; Vault — 8200 от ESO/ingress/monitoring и ничего наружу; ESO — webhook от apiserver и egress только в Vault;
  argocd/monitoring — свободно внутри namespace, снаружи только ingress-nginx и Prometheus, egress не ограничен (git,
  helm-репозитории, scrape всего кластера); ingress-nginx — вход отовсюду, выход везде (ограничение — на стороне получателя).

Семантика: правило первого совпадения по order; kubelet-пробы Calico пропускает всегда; webhook-порты (ESO 10250,
VPA 8000, prometheus-operator 10250) открыты без источника — apiserver вне сети подов (IP ноды). Политики — в проекте
`platform`, проекту `shop` NetworkPolicy запрещены (`namespaceResourceBlacklist`): приложение не может открыть себе Vault.

Проверка после включения: 19/19 Application Synced/Healthy, e2e-заказ проходит, из пода orders `vault.vault:8200` и
`api.github.com:443` — timeout, Whisker показывает deny с политикой `default-deny`.

## Дальше

1. ResourceQuota/LimitRange, Job/CronJob (миграции как helm hook).
2. RBAC для людей (k8s), cert-manager + TLS. Argo: SSO через Dex/GitHub (+ отключить admin), ApplicationSet/окружения
   (см. заметки в чате: envs/ папками, git files generator), notifications, Rollouts.
3. HPA по метрикам Prometheus (prometheus-adapter) и KEDA для notifier по длине очереди.
