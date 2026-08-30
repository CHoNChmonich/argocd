#!/usr/bin/env bash
# Создать локальный кластер по cluster/kind-config.yaml (идемпотентно) и подключить локальный registry.
# Дальше: scripts/build-images.sh, scripts/publish-chart.sh, cluster/bootstrap.sh.
#
# Kubernetes в Docker Desktop должен быть ВЫКЛЮЧЕН (Settings -> Kubernetes): его провизионер тоже kind,
# но без настроек CNI, и он пересоздаёт кластер при каждом перезапуске Docker. Этот кластер — обычные
# docker-контейнеры shop-control-plane/shop-worker*, они переживают перезапуск Docker вместе с данными PVC.
set -euo pipefail
cd "$(dirname "$0")/.."
KIND=${KIND:-kind}   # winget install Kubernetes.kind
NAME=$(python -c "import yaml,sys;print(yaml.safe_load(open('cluster/kind-config.yaml'))['name'])" 2>/dev/null || echo shop)

if "$KIND" get clusters 2>/dev/null | grep -qx "$NAME"; then
  echo ">> кластер $NAME уже есть (kind delete cluster --name $NAME — пересоздать)"
else
  "$KIND" create cluster --config cluster/kind-config.yaml
fi
kubectl config use-context "kind-$NAME" >/dev/null
bash cluster/registry.sh
echo ">> ноды NotReady — это нормально: CNI (Calico) ставит cluster/bootstrap.sh"
