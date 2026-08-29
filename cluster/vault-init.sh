#!/usr/bin/env bash
# Vault: init / unseal / базовая настройка / наполнение. Идемпотентен — можно запускать сколько угодно.
# Это единственный шаг, который нельзя описать в git: значения секретов и unseal-ключ по определению вне репозитория.
#
#   init    — один раз: создаёт unseal-ключ и root-токен -> cluster/secrets/vault-init.json (в .gitignore!)
#   unseal  — после каждого рестарта пода (прод: auto-unseal через KMS, здесь — ключом из файла)
#   setup   — KV v2 на secret/, Kubernetes auth, политика eso-read, роль eso для ServiceAccount ESO
#   seed    — пароли, которых ещё нет в Vault (случайные); существующие не трогает.
#             Ротация: vault kv put secret/shop/redis redis-password=... ; ESO подтянет за refreshInterval,
#             потребителей перезапустить (env читается при старте пода).
set -euo pipefail
cd "$(dirname "$0")/.."
NS=vault; POD=vault-0; INIT=cluster/secrets/vault-init.json
v() { kubectl -n "$NS" exec -i "$POD" -- sh -c "VAULT_TOKEN=\${VAULT_TOKEN:-} $*"; }

echo ">> жду под $POD"
for i in $(seq 1 60); do kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running && break; sleep 5; done

# ---- init / unseal
if ! v vault status -format=json 2>/dev/null | grep -q '"initialized": *true'; then
  echo ">> init (1 unseal-ключ из 1 — лаба; прод: 5 из 3 или KMS auto-unseal)"
  mkdir -p cluster/secrets
  v vault operator init -key-shares=1 -key-threshold=1 -format=json > "$INIT"
fi
[ -f "$INIT" ] || { echo "!! $INIT не найден: Vault инициализирован, но ключа нет — восстановить нельзя"; exit 1; }
UNSEAL=$(python -c "import json,sys;print(json.load(open('$INIT'))['unseal_keys_b64'][0])")
ROOT=$(python -c "import json,sys;print(json.load(open('$INIT'))['root_token'])")
if v vault status -format=json 2>/dev/null | grep -q '"sealed": *true'; then
  echo ">> unseal"; v vault operator unseal "$UNSEAL" >/dev/null
fi
export VAULT_TOKEN="$ROOT"
vt() { kubectl -n "$NS" exec -i "$POD" -- env VAULT_TOKEN="$ROOT" "$@"; }

# ---- setup
vt vault secrets list -format=json | grep -q '"secret/"' || { echo ">> KV v2 на secret/"; vt vault secrets enable -path=secret kv-v2 >/dev/null; }
vt vault auth list -format=json | grep -q '"kubernetes/"' || { echo ">> auth kubernetes"; vt vault auth enable kubernetes >/dev/null; }
# Vault проверяет SA-токены клиентов через TokenReview своим собственным SA-токеном (chart: authDelegator)
vt vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443" >/dev/null
vt sh -c 'vault policy write eso-read - <<EOF
path "secret/data/*"     { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read", "list"] }
EOF' >/dev/null
vt vault write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets bound_service_account_namespaces=external-secrets \
  policies=eso-read ttl=1h >/dev/null
echo ">> setup: kv-v2 secret/, auth kubernetes, policy eso-read, role eso"

# ---- seed: только отсутствующие
gen() { python -c "import secrets;print(secrets.token_urlsafe(24))"; }
seed() { # seed <path> key=value ...
  local path=$1; shift
  if vt vault kv get -format=json "secret/$path" >/dev/null 2>&1; then echo "   secret/$path: есть"; return; fi
  vt vault kv put "secret/$path" "$@" >/dev/null; echo "   secret/$path: создан"
}
echo ">> seed"
seed shop/postgresql password="$(gen)" postgres-password="$(gen)"
seed shop/redis redis-password="$(gen)"
seed shop/rabbitmq rabbitmq-password="$(gen)" rabbitmq-erlang-cookie="$(gen)"
seed monitoring/grafana-admin admin-user=admin admin-password="$(gen)"
if ! vt vault kv get -format=json secret/argocd/argocd-secret >/dev/null 2>&1; then
  ADMIN=$(gen)
  # bcrypt считает argocd (в поде argocd-server); server.secretkey подписывает JWT-сессии; webhook — HMAC GitHub
  HASH=$(kubectl -n argocd exec deploy/argocd-server -- argocd account bcrypt --password "$ADMIN")
  seed argocd/argocd-secret admin.password="$HASH" admin.passwordMtime="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    server.secretkey="$(gen)" webhook.github.secret="$(gen)"
  echo ">> admin-пароль Argo CD (UI: http://argocd.shop.localtest.me, логин admin): $ADMIN"
fi
echo ">> Vault UI: http://vault.shop.localtest.me (root token в $INIT — в проде root отзывают после настройки)"
