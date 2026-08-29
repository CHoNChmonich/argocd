#!/usr/bin/env bash
# Обёртка над vault CLI внутри пода vault-0 с root-токеном из cluster/secrets/vault-init.json (лаба).
# Прод: vault CLI на рабочей машине, VAULT_ADDR=https://vault..., персональный токен через OIDC/GitHub auth —
# никаких root-токенов у людей, каждое действие в аудите под своим именем.
#
#   scripts/vault.sh kv list secret/shop
#   scripts/vault.sh kv get  secret/shop/redis
#   scripts/vault.sh kv put  secret/shop/newthing api-key=...          # создать / перезаписать (все ключи!)
#   scripts/vault.sh kv patch secret/shop/postgresql password=...      # изменить один ключ, остальные оставить
#   scripts/vault.sh kv metadata get secret/shop/redis                 # версии
#   scripts/vault.sh kv get -version=1 secret/shop/redis               # прочитать старую версию
#   scripts/vault.sh kv rollback -version=1 secret/shop/redis          # откат = новая версия со старыми данными
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(python -c "import json;print(json.load(open('cluster/secrets/vault-init.json'))['root_token'])")
exec kubectl -n vault exec -i vault-0 -- env VAULT_TOKEN="$ROOT" vault "$@"
