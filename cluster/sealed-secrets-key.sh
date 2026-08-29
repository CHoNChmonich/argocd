#!/usr/bin/env bash
# Бэкап активного ключа Sealed Secrets в cluster/secrets/ (в .gitignore). В проде — в Vault/KMS/оффлайн-хранилище.
# Восстанавливает cluster/bootstrap.sh при пересоздании кластера.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p cluster/secrets
kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml > cluster/secrets/sealed-secrets-key.yaml
echo ">> cluster/secrets/sealed-secrets-key.yaml ($(grep -c 'kind: Secret' cluster/secrets/sealed-secrets-key.yaml) ключ)"
