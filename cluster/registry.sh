#!/usr/bin/env bash
# Локальный container registry для kind-кластера (официальный паттерн kind:
# https://kind.sigs.k8s.io/docs/user/local-registry/).
#
#  docker push localhost:5001/shop/orders:dev   <- с хоста
#  image: localhost:5001/shop/orders:dev        <- в манифестах; ноды резолвят localhost:5001
#                                                  в kind-registry:5000 через containerd hosts.toml
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: не переписывать /etc/... в C:/Program Files/Git/etc/...

REG_NAME=kind-registry
REG_PORT=5001
NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')

if [ "$(docker inspect -f '{{.State.Running}}' "$REG_NAME" 2>/dev/null || true)" != "true" ]; then
  echo ">> starting registry $REG_NAME on localhost:$REG_PORT"
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --name "$REG_NAME" registry:2 >/dev/null
fi

# registry должен быть в одной сети с нодами, чтобы имя kind-registry резолвилось
if ! docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$REG_NAME" | grep -q '"IPAddress"'; then
  docker network connect kind "$REG_NAME"
fi

# containerd на каждой ноде: localhost:5001 -> http://kind-registry:5000
for node in $NODES; do
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/localhost:${REG_PORT}"
  printf '[host."http://%s:5000"]\n' "$REG_NAME" \
    | docker exec -i "$node" tee "/etc/containerd/certs.d/localhost:${REG_PORT}/hosts.toml" >/dev/null
  echo ">> $node configured"
done

# конвенция KEP-1755: сообщить инструментам, что в кластере есть локальный registry
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
echo ">> registry ready: localhost:${REG_PORT}"
