#!/usr/bin/env bash
# Собирает три образа и пушит в локальный registry (см. cluster/registry.sh).
# Ноды kind не видят образы docker CLI — единственный "правильный" путь в кластер лежит через registry.
set -euo pipefail
cd "$(dirname "$0")/../services"
REGISTRY="${REGISTRY:-localhost:5001}"
TAG="${TAG:-dev}"
for svc in orders inventory notifier; do
  docker build --target "$svc" -t "$REGISTRY/shop/$svc:$TAG" .
  docker push "$REGISTRY/shop/$svc:$TAG"
done
echo ">> in registry:"
curl -s "http://$REGISTRY/v2/_catalog"
