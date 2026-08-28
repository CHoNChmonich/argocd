#!/usr/bin/env bash
# Bootstrap кластера в GitOps-режиме. Руками ставится ТОЛЬКО Argo CD и корневой Application;
# всё остальное (мониторинг, ingress, metrics-server, VPA, БД, брокер, приложение) Argo CD
# поднимает сам из git (gitops/platform, gitops/apps), чарты берёт из helm/OCI-репозиториев,
# values — из этого репозитория (infra/values), порядок — sync-waves.
#
# Предусловия: кластер, локальный registry (cluster/registry.sh), образы и чарт shop запушены
# (scripts/build-images.sh, scripts/publish-chart.sh), репозиторий запушен в GitHub — Argo читает его по сети.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGOCD_CHART_VERSION=10.4.0   # argo/argo-cd; та же версия в gitops/platform/00-argo-cd.yaml (self-managing)

# Первый запуск: helm только рендерит (helm template), применяет kubectl. Helm-релиз не создаётся —
# дальше этими объектами владеет Application argo-cd (gitops/platform/00-argo-cd.yaml), и второй
# "владелец" в виде протухшего релиза (helm list) только вводил бы в заблуждение.
echo ">> argo-cd $ARGOCD_CHART_VERSION (helm template | kubectl apply)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm template argo-cd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --include-crds \
  -f infra/values/argo-cd.yaml \
  | kubectl apply --server-side --force-conflicts -n argocd -f -
kubectl -n argocd rollout status deploy/argocd-server --timeout=10m
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=10m
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=10m

echo ">> AppProject bootstrap + root Application (app of apps)"
kubectl apply -f gitops/bootstrap/

echo ">> admin-пароль Argo CD (UI: http://argocd.shop.localtest.me, логин admin):"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

echo ">> состояние Application'ов (обновляется по мере синхронизации):"
kubectl -n argocd get applications
