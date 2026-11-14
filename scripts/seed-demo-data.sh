#!/usr/bin/env bash
# Deixa o ambiente pronto para a demonstração: usuário no Keycloak, catálogo
# com cinco jogos, índice do Elasticsearch populado e, opcionalmente, uma
# compra para gerar o log de eventos no MongoDB.
#
# Idempotente: reexecutar não duplica usuário nem jogo.
#
# Uso:
#   bash scripts/seed-demo-data.sh              # semeia e faz uma compra
#   COMPRA=0 bash scripts/seed-demo-data.sh     # só semeia
#   GATEWAY=http://localhost:8000 bash scripts/seed-demo-data.sh
#
# Sem GATEWAY, descobre o IP do Load Balancer do kong-proxy. As credenciais
# saem do .env (fora do Git); a senha do usuário de demonstração é gerada e
# gravada lá na primeira execução.
#
# Requer: kubectl com acesso ao cluster, curl, jq, python3.
set -uo pipefail

NAMESPACE="${NAMESPACE:-fiap-games}"
REALM="${REALM:-TechChallengeFiap}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
KC_PORT="${KC_PORT:-18081}"
COMPRA="${COMPRA:-1}"

for t in kubectl curl jq python3; do
  command -v "$t" > /dev/null || { echo "ERRO: $t não encontrado." >&2; exit 1; }
done
[ -f "$ENV_FILE" ] || { echo "ERRO: $ENV_FILE não existe. Copie o .env.example." >&2; exit 1; }

set -a; . "$ENV_FILE"; set +a
: "${KEYCLOAK_ADMIN:?defina KEYCLOAK_ADMIN no .env}"
: "${KEYCLOAK_ADMIN_PASSWORD:?defina KEYCLOAK_ADMIN_PASSWORD no .env}"

# ─── Endereço do gateway ─────────────────────────────────────────────────────
if [ -z "${GATEWAY:-}" ]; then
  IP="$(kubectl get svc kong-proxy -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [ -n "$IP" ]; then
    GATEWAY="http://$IP:8000"
  else
    echo "ERRO: kong-proxy sem IP externo. Em cluster local, use port-forward e" >&2
    echo "      passe GATEWAY=http://localhost:8000." >&2
    exit 1
  fi
fi
echo "Gateway: $GATEWAY"

# ─── Usuário de demonstração ─────────────────────────────────────────────────
if ! grep -q "^DEMO_PASSWORD=" "$ENV_FILE"; then
  DEMO_USERNAME="${DEMO_USERNAME:-demo.fase4}"
  DEMO_PASSWORD="$(python3 -c "import secrets,string;a=string.ascii_letters+string.digits;print(''.join(secrets.choice(a) for _ in range(20))+'!A1')")"
  {
    echo ""
    echo "# Usuário de demonstração (gerado por scripts/seed-demo-data.sh)"
    echo "DEMO_USERNAME=$DEMO_USERNAME"
    echo "DEMO_PASSWORD=$DEMO_PASSWORD"
  } >> "$ENV_FILE"
  echo "→ senha do usuário de demonstração gerada e gravada no .env"
  set -a; . "$ENV_FILE"; set +a
else
  echo "✓ credenciais de demonstração já estão no .env"
fi

# O Keycloak é ClusterIP: a API de administração só por port-forward.
kubectl port-forward -n "$NAMESPACE" "svc/keycloak" "$KC_PORT:80" > /dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 25); do
  curl -sf -m 2 "http://localhost:$KC_PORT/realms/master" > /dev/null && break
  sleep 1
done

ADMIN_TOKEN="$(curl -s -X POST "http://localhost:$KC_PORT/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d grant_type=password \
  --data-urlencode "username=$KEYCLOAK_ADMIN" \
  --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" | jq -r '.access_token // empty')"
[ -n "$ADMIN_TOKEN" ] || { echo "ERRO: login de admin no Keycloak falhou." >&2; exit 1; }

JA_EXISTE="$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://localhost:$KC_PORT/admin/realms/$REALM/users?username=$DEMO_USERNAME&exact=true" | jq 'length')"
if [ "$JA_EXISTE" = "0" ]; then
  # Gender e DateOfBirth são obrigatórios no user profile declarativo do realm —
  # sem eles o Keycloak recusa com error-user-attribute-required.
  CODE="$(curl -s -o /tmp/seed-kc.json -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    "http://localhost:$KC_PORT/admin/realms/$REALM/users" \
    -d "$(jq -nc --arg u "$DEMO_USERNAME" --arg p "$DEMO_PASSWORD" '{
      username: $u, email: ($u + "@fiap.com.br"), firstName: "Demo", lastName: "Fase4",
      enabled: true, emailVerified: true,
      attributes: { Gender: ["Outro"], DateOfBirth: ["1995-01-01"] },
      credentials: [{ type: "password", value: $p, temporary: false }]
    }')")"
  if [ "$CODE" != "201" ]; then
    echo "ERRO ao criar usuário (HTTP $CODE):" >&2; head -c 400 /tmp/seed-kc.json >&2; echo >&2; exit 1
  fi
  echo "→ usuário $DEMO_USERNAME criado"
else
  echo "✓ usuário $DEMO_USERNAME já existe"
fi

# ─── Token da aplicação ──────────────────────────────────────────────────────
# POST /api/auth/login usa [FromForm]: vai como formulário, não como JSON.
TOKEN="$(curl -s -m 30 -X POST "$GATEWAY/api/auth/login" \
  --form-string "username=$DEMO_USERNAME" --form-string "password=$DEMO_PASSWORD" \
  | jq -r '.access_token // empty')"
if [ -z "$TOKEN" ]; then
  echo "ERRO: login pelo gateway falhou. Se o Keycloak subiu agora, rode" >&2
  echo "      scripts/configure-kong-jwt.sh — o Kong pode estar com a chave placeholder." >&2
  exit 1
fi
echo "✓ login pelo gateway OK"

# ─── Catálogo ────────────────────────────────────────────────────────────────
TITULOS_EXISTENTES="$(curl -s -m 30 "$GATEWAY/api/game" -H "Authorization: Bearer $TOKEN" | jq -r '.[]?.title // empty')"

semear() {
  local titulo="$1" corpo="$2"
  if printf '%s\n' "$TITULOS_EXISTENTES" | grep -qxF "$titulo"; then
    echo "  ✓ $titulo (já existe)"
    return
  fi
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST "$GATEWAY/api/game" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$corpo")"
  echo "  $code $titulo"
}

echo "→ catálogo:"
semear "Counter-Strike 2" '{"title":"Counter-Strike 2","description":"FPS tatico competitivo em partidas 5v5.","basePrice":120.00,"developer":"Valve","publisher":"Valve","genres":["FPS","Competitivo"],"releaseDate":"2023-09-27"}'
semear "The Witcher 3: Wild Hunt" '{"title":"The Witcher 3: Wild Hunt","description":"RPG de mundo aberto com Geralt de Rivia.","basePrice":99.90,"developer":"CD Projekt Red","publisher":"CD Projekt","genres":["RPG","Mundo Aberto"],"releaseDate":"2015-05-19"}'
semear "Minecraft" '{"title":"Minecraft","description":"Sandbox de construcao e sobrevivencia em blocos.","basePrice":89.90,"developer":"Mojang","publisher":"Microsoft","genres":["Sandbox","Sobrevivencia"],"releaseDate":"2011-11-18"}'
semear "Elden Ring" '{"title":"Elden Ring","description":"RPG de acao em mundo aberto da FromSoftware.","basePrice":249.90,"developer":"FromSoftware","publisher":"Bandai Namco","genres":["RPG","Acao"],"releaseDate":"2022-02-25"}'
semear "Stardew Valley" '{"title":"Stardew Valley","description":"Simulador de fazenda com vida no interior.","basePrice":24.99,"developer":"ConcernedApe","publisher":"ConcernedApe","genres":["Simulacao","Indie"],"releaseDate":"2016-02-26"}'

# Reconcilia o índice: garante que a busca enxerga tudo, inclusive jogos que
# existiam antes de o Elasticsearch entrar no ar.
echo "→ reindexando: HTTP $(curl -s -o /dev/null -w '%{http_code}' -m 60 -X POST "$GATEWAY/api/search/reindex" -H "Authorization: Bearer $TOKEN")"

# ─── Compra: alimenta o log de eventos no MongoDB ────────────────────────────
if [ "$COMPRA" = "1" ]; then
  GAME_ID="$(curl -s -m 30 "$GATEWAY/api/game" -H "Authorization: Bearer $TOKEN" | jq -r '.[0].gameId // empty')"
  if [ -n "$GAME_ID" ]; then
    CID="$(curl -s -m 40 -X POST "$GATEWAY/api/purchase" -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" -d "{\"gameId\":$GAME_ID}" | jq -r '.correlationId // empty')"
    if [ -n "$CID" ]; then
      echo "→ compra criada · correlationId: $CID"
      echo "  os eventos levam alguns segundos para atravessar o Kafka:"
      echo "    curl -s $GATEWAY/api/eventlog/$CID -H \"Authorization: Bearer \$TOKEN\" | jq"
    fi
  fi
fi

cat <<FIM

Pronto. Para a demonstração:

  TOKEN=\$(curl -s -X POST $GATEWAY/api/auth/login \\
    --form-string "username=$DEMO_USERNAME" --form-string "password=\$DEMO_PASSWORD" | jq -r .access_token)

  curl -s "$GATEWAY/api/search?q=couter%20strke" | jq '.items[] | {title, score}'
  time curl -s "$GATEWAY/api/game/1" -H "Authorization: Bearer \$TOKEN" > /dev/null
FIM
