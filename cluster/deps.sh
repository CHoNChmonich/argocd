#!/usr/bin/env bash
# Зависимости приложения (Postgres, Redis, RabbitMQ, Jaeger) — helm-релизы из infra/charts в namespace shop.
# Namespace создаётся манифестом приложения (там Pod Security labels), поэтому применяем его первым.
set -euo pipefail
cd "$(dirname "$0")/.."

kubectl apply -f cluster/namespace-shop.yaml

for chart in postgresql redis rabbitmq jaeger; do
  echo ">> $chart"
  helm upgrade --install "$chart" "./infra/charts/$chart" \
    --namespace shop \
    -f "infra/values/$chart.yaml" \
    --wait --timeout 10m
done

echo ">> done"
helm list -n shop
kubectl get pods,pvc -n shop
