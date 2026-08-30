#!/usr/bin/env bash
# Bootstrap кластера в GitOps-режиме. Руками ставится ТОЛЬКО Argo CD и корневой Application;
# всё остальное (мониторинг, ingress, metrics-server, VPA, БД, брокер, приложение) Argo CD
# поднимает сам из git (gitops/platform, gitops/apps), чарты берёт из helm/OCI-репозиториев,
# values — из этого репозитория (infra/values), порядок — sync-waves.
#
# Предусловия: кластер и registry (cluster/kind-up.sh), образы и чарт shop запушены
# (scripts/build-images.sh, scripts/publish-chart.sh), репозиторий запушен в GitHub — Argo читает его по сети.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGOCD_CHART_VERSION=10.4.0   # argo/argo-cd; та же версия в gitops/platform/00-argo-cd.yaml (self-managing)
CALICO_CHART_VERSION=v3.32.1  # projectcalico/tigera-operator; та же версия в gitops/platform/00-calico.yaml

# ---- 0. CNI. Кластер создан с disableDefaultCNI (cluster/kind-config.yaml): ноды NotReady, поды Pending,
# пока нет CNI. Calico ставится так же, как Argo: helm только рендерит, владеет объектами потом Application calico.
# --no-hooks: в чарте есть Job с helm.sh/hook pre-delete (деинсталляция) — kubectl про хуки не знает и запустил бы его.
# CRD оператор создаёт сам при старте, поэтому CR (Installation, Goldmane, Whisker) применяются вторым проходом.
echo ">> calico $CALICO_CHART_VERSION (helm template | kubectl apply)"
helm repo add projectcalico https://docs.tigera.io/calico/charts >/dev/null 2>&1 || true
helm repo update projectcalico >/dev/null
kubectl create namespace tigera-operator --dry-run=client -o yaml | kubectl apply -f -
calico() { helm template calico projectcalico/tigera-operator --version "$CALICO_CHART_VERSION"   --namespace tigera-operator --no-hooks -f infra/values/calico.yaml   | kubectl apply --server-side --force-conflicts -n tigera-operator -f - ; }
calico 2>/dev/null || true                        # первый проход: оператор; CR ещё отклоняются
for i in $(seq 1 60); do kubectl get crd installations.operator.tigera.io >/dev/null 2>&1 && break; sleep 5; done
calico                                            # второй проход: CR приняты
for i in $(seq 1 60); do kubectl -n calico-system get ds calico-node >/dev/null 2>&1 && break; sleep 5; done
kubectl -n calico-system rollout status ds/calico-node --timeout=10m
kubectl wait --for=condition=Ready nodes --all --timeout=5m

# Первый запуск: helm только рендерит (helm template), применяет kubectl. Helm-релиз не создаётся —
# дальше этими объектами владеет Application argo-cd (gitops/platform/00-argo-cd.yaml), и второй
# "владелец" в виде протухшего релиза (helm list) только вводил бы в заблуждение.
echo ">> 1. argo-cd $ARGOCD_CHART_VERSION (helm template | kubectl apply)"
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

# Vault: init/unseal/наполнение — после root, когда Argo создал Application vault (wave -1) и под vault-0 поднялся.
# Пароли (в т.ч. admin Argo) рождаются здесь и попадают в кластер через ESO; argocd-initial-admin-secret не создаётся.
bash cluster/vault-init.sh

echo ">> состояние Application'ов (обновляется по мере синхронизации):"
kubectl -n argocd get applications
