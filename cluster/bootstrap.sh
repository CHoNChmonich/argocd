#!/usr/bin/env bash
# Инфраструктурные компоненты кластера (не приложение): мониторинг, ingress-controller, metrics-server, VPA.
# Чарты лежат в репозитории (infra/charts/<chart>, скачаны infra/vendor.sh), наши values — в infra/values.
# Ставятся как Helm-релизы из ЛОКАЛЬНОГО пути: helm upgrade --install <release> ./infra/charts/<chart>
#
# Порядок важен: kube-prometheus-stack первым — он приносит CRD (ServiceMonitor, PrometheusRule),
# на которые ссылаются values ingress-nginx и чартов зависимостей (cluster/deps.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

echo ">> kube-prometheus-stack (Prometheus Operator + Prometheus + Alertmanager + Grafana + exporters)"
helm upgrade --install kube-prometheus-stack ./infra/charts/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f infra/values/kube-prometheus-stack.yaml \
  --wait --timeout 10m

echo ">> loki (хранилище логов, single-binary)"
helm upgrade --install loki ./infra/charts/loki \
  --namespace monitoring \
  -f infra/values/loki.yaml \
  --wait --timeout 10m

echo ">> alloy (DaemonSet: читает логи подов через kubelet и шлёт в Loki)"
helm upgrade --install alloy ./infra/charts/alloy \
  --namespace monitoring \
  -f infra/values/alloy.yaml \
  --wait --timeout 5m

echo ">> ingress-nginx"
helm upgrade --install ingress-nginx ./infra/charts/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f infra/values/ingress-nginx.yaml \
  --wait --timeout 5m

echo ">> metrics-server (нужен для HPA и kubectl top)"
helm upgrade --install metrics-server ./infra/charts/metrics-server \
  --namespace kube-system \
  -f infra/values/metrics-server.yaml \
  --wait --timeout 5m

echo ">> vertical-pod-autoscaler (recommender / updater / admission webhook)"
helm upgrade --install vpa ./infra/charts/vpa \
  --namespace vpa --create-namespace \
  -f infra/values/vpa.yaml \
  --wait --timeout 5m

echo ">> done"
helm list -A
kubectl get svc -n ingress-nginx ingress-nginx-controller
