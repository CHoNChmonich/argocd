#!/usr/bin/env bash
# Запечатать секрет для git. Пример:
#   scripts/seal.sh shop postgresql password=... postgres-password=...   > secrets/shop/postgresql.yaml
# Шифрует публичным ключом контроллера (берёт его из кластера); расшифровать может только контроллер.
# Запечатанный секрет привязан к namespace+имени (scope strict) — в другой namespace его не перенести.
set -euo pipefail
NS=$1; NAME=$2; shift 2
args=(); for kv in "$@"; do args+=(--from-literal="$kv"); done
kubectl create secret generic "$NAME" -n "$NS" --dry-run=client -o yaml "${args[@]}"   | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets -o yaml
