#!/usr/bin/env bash
# Bootstrap кластера в GitOps-режиме. Руками ставится ТОЛЬКО Argo CD и корневой Application;
# всё остальное (мониторинг, ingress, metrics-server, VPA, БД, брокер, приложение) Argo CD
# поднимает сам из git (gitops/platform, gitops/apps), соблюдая порядок через sync-waves.
#
# Предусловия: кластер, локальный registry (cluster/registry.sh), образы запушены (scripts/build-images.sh),
# репозиторий запушен в GitHub — Argo читает его по сети, локальная папка ему недоступна.
set -euo pipefail
cd "$(dirname "$0")/.."

echo ">> argo-cd (единственный helm-релиз, который ставится руками)"
helm upgrade --install argo-cd ./infra/charts/argo-cd \
  --namespace argocd --create-namespace \
  -f infra/values/argo-cd.yaml \
  --wait --timeout 10m

echo ">> root Application (app of apps)"
kubectl apply -f gitops/bootstrap/root.yaml

echo ">> admin-пароль Argo CD (UI: http://argocd.shop.localtest.me, логин admin):"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

echo ">> состояние Application'ов (обновляется по мере синхронизации):"
kubectl -n argocd get applications
