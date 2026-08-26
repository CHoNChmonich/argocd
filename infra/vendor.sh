#!/usr/bin/env bash
# Скачивает исходники внешних чартов в infra/charts/ (vendoring).
# Чарт — это tar.gz с Chart.yaml + templates/ + values.yaml; здесь он распакован и закоммичен,
# чтобы было видно, что именно ставится, и чтобы обновление версии было diff'ом в PR.
#
# Обновить компонент: поменять версию ниже, запустить скрипт, посмотреть git diff, закоммитить.
# Два вида источников: классический helm-репозиторий (alias/chart, нужен helm repo add)
# и OCI-registry (oci://..., repo add не нужен — чарт лежит рядом с образами).
set -euo pipefail
cd "$(dirname "$0")"

declare -A CHARTS=(
  # <источник>                                               <версия чарта>
  [ingress-nginx/ingress-nginx]=4.15.1
  [metrics-server/metrics-server]=3.14.0
  [jaegertracing/jaeger]=3.4.1
  [fairwinds-stable/vpa]=5.0.0
  [prometheus-community/kube-prometheus-stack]=88.5.4
  [grafana/loki]=7.3.0
  [grafana/alloy]=1.12.0
  [oci://registry-1.docker.io/bitnamicharts/postgresql]=16.7.27
  [oci://registry-1.docker.io/bitnamicharts/redis]=20.13.4
  [oci://registry-1.docker.io/bitnamicharts/rabbitmq]=16.0.14
)

helm repo add ingress-nginx  https://kubernetes.github.io/ingress-nginx        >/dev/null 2>&1 || true
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo add jaegertracing  https://jaegertracing.github.io/helm-charts        >/dev/null 2>&1 || true
helm repo add fairwinds-stable https://charts.fairwinds.com/stable                >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

mkdir -p charts
for ref in "${!CHARTS[@]}"; do
  name=${ref##*/}
  version=${CHARTS[$ref]}
  rm -rf "charts/$name"
  helm pull "$ref" --version "$version" --untar --untardir charts
  echo ">> $ref $version -> charts/$name"
done
echo
grep -E "^(name|version|appVersion):" charts/*/Chart.yaml
