#!/usr/bin/env bash
# В GitOps-режиме деплой = коммит в git. Этот скрипт: проверить чарт локально, запушить,
# попросить Argo CD перечитать репозиторий немедленно (иначе — до 60 с) и дождаться Synced/Healthy.
#
#   scripts/deploy.sh             # lint + template + push + refresh + wait
#   scripts/deploy.sh template    # только рендер
set -euo pipefail
cd "$(dirname "$0")/.."

APP=shop
VALUES=(-f charts/shop/values-lab.yaml)

if [ "${1:-}" = "template" ]; then
  helm template "$APP" ./charts/shop -n shop "${VALUES[@]}" \
    --api-versions monitoring.coreos.com/v1 --api-versions autoscaling.k8s.io/v1
  exit
fi

helm lint ./charts/shop "${VALUES[@]}"

if [ -n "$(git status --porcelain charts/shop gitops)" ]; then
  echo "!! есть незакоммиченные изменения в charts/shop или gitops/ — Argo видит только то, что в git (origin/main)"
  git status --short charts/shop gitops
  exit 1
fi
git push -q origin main

echo ">> refresh Application $APP"
kubectl -n argocd annotate application "$APP" argocd.argoproj.io/refresh=normal --overwrite >/dev/null

echo ">> ожидание Synced/Healthy"
for i in $(seq 1 60); do
  s=$(kubectl -n argocd get application "$APP" -o jsonpath='{.status.sync.status}/{.status.health.status}')
  [ "$s" = "Synced/Healthy" ] && { echo "   $s"; break; }
  sleep 5
done
kubectl -n argocd get application "$APP"
kubectl -n shop get deploy,hpa -l app.kubernetes.io/instance="$APP"
