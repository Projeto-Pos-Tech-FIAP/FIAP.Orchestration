#!/usr/bin/env bash
#
# Busca a chave pública RSA atual do realm TechChallengeFiap no Keycloak
# (via JWKS) e a grava no ConfigMap kong-declarative-config, que o Kong usa
# para validar a assinatura dos tokens JWT (plugin `jwt`).
#
# Por quê um script em vez de hardcodar a chave no kong.yml commitado? O
# Keycloak gera um par de chaves RSA novo a cada realm importado do zero,
# então a chave pública real só existe depois que o pod do Keycloak sobe
# pela primeira vez — não dá pra versionar um valor que ainda não existe no
# momento do commit. (A chave em si não é secreta: é a mesma que qualquer
# cliente já lê sem autenticação em .../protocol/openid-connect/certs — por
# isso ela vive num ConfigMap normal, não num Secret.)
#
# Uso:
#   kubectl apply -k k8s/                    # sobe tudo (Kong começa com uma chave placeholder)
#   ./scripts/configure-kong-jwt.sh           # busca a chave real e reconfigura o Kong
#
# Requer: kubectl, curl, jq, openssl, python3.

set -euo pipefail

NAMESPACE="${NAMESPACE:-fiap-games}"
REALM="${REALM:-TechChallengeFiap}"
LOCAL_PORT="${LOCAL_PORT:-8081}"
DEPLOYMENT_NAME="kong-gateway"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGMAP_FILE="${SCRIPT_DIR}/../k8s/gateway/kong-configmap.yaml"

for bin in kubectl curl jq openssl python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Erro: '$bin' não encontrado no PATH." >&2; exit 1; }
done

if [[ ! -f "$CONFIGMAP_FILE" ]]; then
  echo "Erro: não encontrei $CONFIGMAP_FILE" >&2
  exit 1
fi

echo "==> Aguardando o Keycloak ficar pronto em ${NAMESPACE}/keycloak..."
kubectl -n "$NAMESPACE" rollout status deployment/keycloak --timeout=180s

PF_PID=""
cleanup() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "==> Abrindo port-forward temporário para svc/keycloak:80 -> localhost:${LOCAL_PORT}..."
kubectl -n "$NAMESPACE" port-forward svc/keycloak "${LOCAL_PORT}:80" >/tmp/kong-jwt-portforward.log 2>&1 &
PF_PID=$!

KEYCLOAK_LOCAL="http://localhost:${LOCAL_PORT}"

echo "==> Aguardando endpoint OIDC do realm ${REALM} responder..."
for _ in $(seq 1 30); do
  if curl -sf "${KEYCLOAK_LOCAL}/realms/${REALM}/.well-known/openid-configuration" >/tmp/kong-jwt-oidc.json 2>/dev/null; then
    break
  fi
  sleep 2
done

if [[ ! -s /tmp/kong-jwt-oidc.json ]]; then
  echo "Erro: não foi possível alcançar o Keycloak em ${KEYCLOAK_LOCAL}. Veja /tmp/kong-jwt-portforward.log" >&2
  exit 1
fi

JWKS_URI=$(jq -r '.jwks_uri' /tmp/kong-jwt-oidc.json)
echo "==> Baixando JWKS de ${JWKS_URI}..."
curl -sf "$JWKS_URI" >/tmp/kong-jwt-jwks.json

X5C=$(jq -r '[.keys[] | select(.use=="sig" and .alg=="RS256")][0].x5c[0]' /tmp/kong-jwt-jwks.json)
if [[ -z "$X5C" || "$X5C" == "null" ]]; then
  echo "Erro: nenhuma chave de assinatura RS256 encontrada no JWKS do Keycloak." >&2
  exit 1
fi

PEM_CERT="/tmp/kong-jwt-keycloak.crt"
PEM_PUBKEY="/tmp/kong-jwt-keycloak-pub.pem"

{
  echo "-----BEGIN CERTIFICATE-----"
  echo "$X5C" | fold -w 64
  echo "-----END CERTIFICATE-----"
} >"$PEM_CERT"

openssl x509 -pubkey -noout -in "$PEM_CERT" >"$PEM_PUBKEY"

echo "==> Chave pública extraída:"
cat "$PEM_PUBKEY"

echo "==> Atualizando ${CONFIGMAP_FILE} (bloco entre os marcadores BEGIN/END-KEYCLOAK-PUBLIC-KEY)..."
python3 - "$CONFIGMAP_FILE" "$PEM_PUBKEY" <<'PYEOF'
import sys
import pathlib

configmap_path = pathlib.Path(sys.argv[1])
pem_path = pathlib.Path(sys.argv[2])

begin_marker = "# BEGIN-KEYCLOAK-PUBLIC-KEY"
end_marker = "# END-KEYCLOAK-PUBLIC-KEY"

lines = configmap_path.read_text().split("\n")
begin_idx = next(i for i, l in enumerate(lines) if begin_marker in l)
end_idx = next(i for i, l in enumerate(lines) if end_marker in l)

key_indent = " " * 12
pem_indent = " " * 14
pem_lines = pem_path.read_text().strip("\n").split("\n")

new_block = [f"{key_indent}rsa_public_key: |"]
new_block += [f"{pem_indent}{line}" for line in pem_lines]

new_lines = lines[: begin_idx + 1] + new_block + lines[end_idx:]
configmap_path.write_text("\n".join(new_lines))
print(f"OK: bloco substituído ({len(pem_lines)} linhas de chave).")
PYEOF

echo "==> Aplicando o ConfigMap atualizado no cluster..."
kubectl apply -f "$CONFIGMAP_FILE"

echo "==> Reiniciando ${DEPLOYMENT_NAME} para recarregar o kong.yml com a chave real..."
kubectl -n "$NAMESPACE" rollout restart deployment/"$DEPLOYMENT_NAME"
kubectl -n "$NAMESPACE" rollout status deployment/"$DEPLOYMENT_NAME" --timeout=120s

rm -f /tmp/kong-jwt-oidc.json /tmp/kong-jwt-jwks.json "$PEM_CERT" "$PEM_PUBKEY"

cat <<'EOF'

==> Kong configurado com a chave pública real do Keycloak.

Fluxo de teste (Gateway como único ponto de entrada):
  # local: kubectl port-forward -n fiap-games svc/kong-proxy 8000:8000
  # (ou http://localhost:30080 se o NodePort for alcançável direto, ex.: kind/Docker Desktop)

  # 1. Login via Gateway -> UsersAPI -> Keycloak (rota pública, sem JWT)
  curl -s -X POST http://localhost:8000/api/auth/login \
    -H "Content-Type: application/json" \
    -d '{"email":"...","password":"..."}'

  # 2. Chamada protegida com o token obtido acima
  curl -s http://localhost:8000/api/users \
    -H "Authorization: Bearer <access_token>"

  # 3. Sem token -> Kong rejeita antes mesmo de chegar na UsersAPI (401)
  curl -i http://localhost:8000/api/users

EOF
