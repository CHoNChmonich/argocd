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
# NB: не "cmd | grep -q": с pipefail grep -q закрывает пайп раньше, kubectl ловит SIGPIPE и условие ложно.
status() { v vault status -format=json 2>/dev/null || true; }

echo ">> жду под $POD"
# Ждём запущенный контейнер, не Ready: readiness-проба чарта — vault status, для sealed/uninit она красная.
for i in $(seq 1 90); do [ "$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].started}' 2>/dev/null)" = true ] && break; sleep 5; done

# ---- init / unseal
if ! grep -q '"initialized": *true' <<<"$(status)"; then
  echo ">> init (1 unseal-ключ из 1 — лаба; прод: 5 из 3 или KMS auto-unseal)"
  mkdir -p cluster/secrets
  v vault operator init -key-shares=1 -key-threshold=1 -format=json > "$INIT.tmp"
  python -c "import json;json.load(open('$INIT.tmp'))['root_token']" || { rm -f "$INIT.tmp"; echo "!! init не удался"; exit 1; }
  mv "$INIT.tmp" "$INIT"
fi
[ -f "$INIT" ] || { echo "!! $INIT не найден: Vault инициализирован, но ключа нет — восстановить нельзя"; exit 1; }
UNSEAL=$(python -c "import json,sys;print(json.load(open('$INIT'))['unseal_keys_b64'][0])")
ROOT=$(python -c "import json,sys;print(json.load(open('$INIT'))['root_token'])")
if grep -q '"sealed": *true' <<<"$(status)"; then
  echo ">> unseal"; v vault operator unseal "$UNSEAL" >/dev/null
fi
export VAULT_TOKEN="$ROOT"
vt() { kubectl -n "$NS" exec -i "$POD" -- env VAULT_TOKEN="$ROOT" "$@"; }

# ---- setup
grep -q '"secret/"' <<<"$(vt vault secrets list -format=json)" || { echo ">> KV v2 на secret/"; vt vault secrets enable -path=secret kv-v2 >/dev/null; }
grep -q '"kubernetes/"' <<<"$(vt vault auth list -format=json)" || { echo ">> auth kubernetes"; vt vault auth enable kubernetes >/dev/null; }
# Vault проверяет SA-токены клиентов через TokenReview своим собственным SA-токеном (chart: authDelegator)
vt vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443" >/dev/null
vt sh -c 'vault policy write eso-read - <<EOF
path "secret/data/*"     { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read", "list"] }
EOF' >/dev/null
vt vault write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets bound_service_account_namespaces=external-secrets \
  policies=eso-read ttl=1h >/dev/null
# Люди: политика platform-admin (полный доступ к secret/*, без администрирования Vault) + userpass.
# Прод: вместо userpass — OIDC (GitHub/Google) и группы -> политики; root-токен отзывается.
vt sh -c 'vault policy write platform-admin - <<EOF
path "secret/*"               { capabilities = ["create","read","update","patch","delete","list"] }
path "sys/mounts"             { capabilities = ["read"] }
path "sys/internal/ui/*"      { capabilities = ["read"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self"  { capabilities = ["update"] }
EOF' >/dev/null
grep -q '"userpass/"' <<<"$(vt vault auth list -format=json)" || { echo ">> auth userpass"; vt vault auth enable userpass >/dev/null; }
if ! vt vault read auth/userpass/users/artem >/dev/null 2>&1; then
  UPW=$(python -c "import secrets;print(secrets.token_urlsafe(12))")
  vt vault write auth/userpass/users/artem password="$UPW" policies=platform-admin token_ttl=8h token_max_ttl=24h >/dev/null
  echo ">> Vault user artem (userpass), пароль: $UPW  — сменить: vault write auth/userpass/users/artem password=NEW"
fi
echo ">> setup: kv-v2 secret/, auth kubernetes + userpass, policies eso-read + platform-admin, role eso, user artem"

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
# ESO проверял Vault, пока тот был sealed, и запомнил ошибку; повторная проверка — по аннотации force-sync.
kubectl annotate clustersecretstore vault external-secrets.io/force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || true
for es in $(kubectl get externalsecret -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}'); do
  kubectl -n "${es%/*}" annotate externalsecret "${es#*/}" external-secrets.io/force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || true
done
echo ">> Vault UI: http://vault.shop.localtest.me (root token в $INIT — в проде root отзывают после настройки)"
