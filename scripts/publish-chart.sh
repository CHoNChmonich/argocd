#!/usr/bin/env bash
# Упаковать charts/shop и опубликовать в локальный OCI-registry (тот же, где образы).
# Argo CD (gitops/apps/shop.yaml) ставит чарт оттуда по версии из Chart.yaml -> после публикации
# новой версии поменяй targetRevision в gitops/apps/shop.yaml и закоммить.
set -euo pipefail
cd "$(dirname "$0")/.."
REGISTRY="${REGISTRY:-localhost:5001}"

helm lint ./charts/shop -f charts/shop/values-lab.yaml
helm package ./charts/shop -d dist >/dev/null
VERSION=$(helm show chart ./charts/shop | awk '/^version:/ {print $2}')
helm push "dist/shop-$VERSION.tgz" "oci://$REGISTRY/charts" --plain-http
echo ">> опубликовано: $REGISTRY/charts/shop:$VERSION"
echo ">> дальше: gitops/apps/shop.yaml -> targetRevision: $VERSION, затем git push"
