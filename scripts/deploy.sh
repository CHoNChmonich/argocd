#!/usr/bin/env bash
# Деплой приложения helm-чартом charts/shop. Зависимости — cluster/deps.sh, платформа — cluster/bootstrap.sh.
#   scripts/deploy.sh            # upgrade --install
#   scripts/deploy.sh diff       # только показать, что изменится (нужен плагин helm-diff) или рендер
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE=shop
NS=shop
VALUES=(-f charts/shop/values-lab.yaml)

kubectl apply -f cluster/namespace-shop.yaml

case "${1:-}" in
  template) helm template "$RELEASE" ./charts/shop -n "$NS" "${VALUES[@]}"; exit ;;
  diff)     helm diff upgrade "$RELEASE" ./charts/shop -n "$NS" "${VALUES[@]}" 2>/dev/null \
              || { echo "helm-diff не установлен: helm plugin install https://github.com/databus23/helm-diff"; exit 1; }; exit ;;
esac

helm lint ./charts/shop "${VALUES[@]}"
helm upgrade --install "$RELEASE" ./charts/shop \
  --namespace "$NS" \
  "${VALUES[@]}" \
  --wait --timeout 5m

echo ">> helm test"
helm test "$RELEASE" -n "$NS" --logs 2>&1 | tail -12
kubectl -n "$NS" get deploy,hpa,pdb,vpa -l app.kubernetes.io/instance="$RELEASE"
