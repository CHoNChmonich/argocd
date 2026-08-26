# k8s pet-project: мини-магазин из трёх микросервисов

Учебный проект для отработки Kubernetes (Ingress, LoadBalancer, HPA, VPA, PDB, …) и Helm.
Этап 1 — само приложение и локальный стенд на docker-compose. Этап 2 — сырые k8s-манифесты (`manifests/`,
теперь только как учебный справочник). Этап 3 — приложение как свой Helm-чарт `charts/shop` (актуальный способ деплоя).

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
charts/shop/         Helm-чарт приложения (этап 3) — то, что реально деплоится
manifests/           сырые k8s-манифесты приложения (этап 2) — справочно, НЕ применяются
infra/charts/        внешние Helm-чарты (vendored), infra/values/ — наши values к ним
cluster/             registry.sh, bootstrap.sh (мониторинг, ingress, metrics-server, VPA), deps.sh (postgres, redis, rabbitmq, jaeger), namespace-shop.yaml
deploy/local/        конфиги для docker-compose (prometheus)
scripts/             build-images.sh, deploy.sh, load.py
docker-compose.yaml  локальный стенд без k8s
```

## Этап 2: Kubernetes (сырые манифесты)

Кластер — Docker Desktop с kind-провизионером (1 control-plane + 2 worker, k8s 1.31).
Helm 3 — только клиент (в кластере ничего не ставится), установлен через `winget install Helm.Helm`.

```bash
bash cluster/registry.sh         # локальный registry localhost:5001, подключён к нодам kind
bash cluster/bootstrap.sh        # helm из infra/charts: kube-prometheus-stack, loki, alloy, ingress-nginx, metrics-server, VPA
bash cluster/deps.sh             # helm: postgresql, redis, rabbitmq, jaeger в namespace shop (StatefulSet + PVC)
bash scripts/build-images.sh     # build + push localhost:5001/shop/{orders,inventory,notifier}:dev
bash scripts/deploy.sh           # helm upgrade --install shop ./charts/shop -f values-lab.yaml + helm test
```

### Внешние чарты хранятся в репозитории (vendoring)

Чарт — это tar.gz с `Chart.yaml + templates/ + values.yaml`. `infra/vendor.sh` скачивает их
(`helm pull --untar`) в `infra/charts/<chart>/`, версии зафиксированы в скрипте; наши переопределения —
в `infra/values/<chart>.yaml`. Установка идёт из локального пути:

```bash
helm upgrade --install ingress-nginx ./infra/charts/ingress-nginx -n ingress-nginx -f infra/values/ingress-nginx.yaml
helm list -A                                   # релизы
helm get values ingress-nginx -n ingress-nginx # что переопределено
helm template ingress-nginx ./infra/charts/ingress-nginx -f infra/values/ingress-nginx.yaml | less   # что будет применено
```

Обновление компонента = поменять версию в `vendor.sh`, перезапустить, посмотреть `git diff` по чарту, `bootstrap.sh`/`deps.sh`.

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

| Файл | Что демонстрирует |
|---|---|
| `cluster/namespace-shop.yaml` | Namespace + Pod Security Standards (`restricted`) — платформенный объект, применяется в `deps.sh`/`deploy.sh` |
| `01-config.yaml` | ConfigMap и Secret, подключаются через `envFrom` |
| `20-inventory.yaml`, `21-*`, `22-*` | Deployment: RollingUpdate, startup/readiness/liveness-пробы, requests/limits, securityContext, downward API; Service ClusterIP |
| `30-ingress.yaml` | Ingress host-based (`orders.shop.localtest.me`) и path-based с rewrite (`shop.localtest.me/api/orders/...`) |
| `40-hpa.yaml` | HPA orders/inventory по CPU (2..6 реплик), `behavior` для скорости scale-up/down |
| `41-pdb.yaml` | PDB orders/inventory (`maxUnavailable: 1`), notifier (`minAvailable: 1`) |
| `42-vpa.yaml` | VPA: orders/inventory `Off` (только рекомендации — конфликт с HPA по CPU), notifier `Initial` |
| `50-monitoring.yaml` | ServiceMonitor на сервисы, PrometheusRule (recording + 5 алертов), ConfigMap с дашбордом Grafana (метрики + панели логов из Loki) |
| `examples/service-types.yaml` | справочно, не применяется: LoadBalancer, NodePort, Headless для сравнения |

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

## Дальше

1. NetworkPolicy, ResourceQuota/LimitRange, Job/CronJob (миграции как helm hook).
2. Секреты: External Secrets / Sealed Secrets вместо паролей в values зависимостей; RBAC; cert-manager + TLS.
3. HPA по метрикам Prometheus (prometheus-adapter) и KEDA для notifier по длине очереди.
