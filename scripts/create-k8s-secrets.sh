#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

NAMESPACE="${NAMESPACE:-fiap-games}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

REQUIRED=(
  MSSQL_SA_PASSWORD
  MONGO_INITDB_ROOT_USERNAME
  MONGO_INITDB_ROOT_PASSWORD
  KEYCLOAK_POSTGRES_USER
  KEYCLOAK_POSTGRES_PASSWORD
  KEYCLOAK_ADMIN
  KEYCLOAK_ADMIN_PASSWORD
  KEYCLOAK_CLIENT_SECRET
  GRAFANA_ADMIN_USER
  GRAFANA_ADMIN_PASSWORD
)

if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key="${line%%=*}"
    if [ -z "${!key:-}" ]; then
      export "$key=${line#*=}"
    fi
  done < "$ENV_FILE"
fi

missing=()
for name in "${REQUIRED[@]}"; do
  if [ -z "${!name:-}" ] || [ "${!name}" = "CHANGE_ME" ]; then
    missing+=("$name")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Variaveis ausentes ou com CHANGE_ME: ${missing[*]}" >&2
  echo "Defina-as em $ENV_FILE ou no ambiente." >&2
  exit 1
fi

apply_secret() {
  local name="$1" label="$2"
  shift 2
  kubectl create secret generic "$name" --namespace "$NAMESPACE" "$@" --dry-run=client -o yaml \
    | kubectl label --local --dry-run=client -f - "$label" -o yaml \
    | kubectl apply -f -
}

sql_connection() {
  printf 'Server=sqlserver,1433;Database=%s;User Id=sa;Password=%s;TrustServerCertificate=True' "$1" "$MSSQL_SA_PASSWORD"
}

cd "$ROOT"
kubectl apply -f k8s/00-namespace.yaml

apply_secret infra-secret tier=infrastructure \
  --from-literal=MSSQL_SA_PASSWORD="$MSSQL_SA_PASSWORD" \
  --from-literal=MONGO_INITDB_ROOT_USERNAME="$MONGO_INITDB_ROOT_USERNAME" \
  --from-literal=MONGO_INITDB_ROOT_PASSWORD="$MONGO_INITDB_ROOT_PASSWORD" \
  --from-literal=KEYCLOAK_POSTGRES_DB=keycloak \
  --from-literal=KEYCLOAK_POSTGRES_USER="$KEYCLOAK_POSTGRES_USER" \
  --from-literal=KEYCLOAK_POSTGRES_PASSWORD="$KEYCLOAK_POSTGRES_PASSWORD" \
  --from-literal=KEYCLOAK_ADMIN="$KEYCLOAK_ADMIN" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD" \
  --from-literal=KEYCLOAK_CLIENT_SECRET="$KEYCLOAK_CLIENT_SECRET" \
  --from-literal=GRAFANA_ADMIN_USER="$GRAFANA_ADMIN_USER" \
  --from-literal=GRAFANA_ADMIN_PASSWORD="$GRAFANA_ADMIN_PASSWORD"

# Busca avancada: o Elasticsearch local sobe com xpack.security.enabled=false, entao
# nao ha credencial a injetar e a variavel fica vazia. Ela so e necessaria para um
# endpoint gerenciado (Elastic Cloud / Amazon OpenSearch) — por isso e opcional e nao
# entra na lista REQUIRED acima.
catalog_extra=()
if [ -n "${ELASTICSEARCH_API_KEY:-}" ]; then
  catalog_extra+=(--from-literal=Elasticsearch__ApiKey="$ELASTICSEARCH_API_KEY")
fi

apply_secret catalog-api-secret app=catalog-api \
  --from-literal=ConnectionStrings__DefaultConnection="$(sql_connection CatalogAPI)" \
  --from-literal=MongoDb__Username="$MONGO_INITDB_ROOT_USERNAME" \
  --from-literal=MongoDb__Password="$MONGO_INITDB_ROOT_PASSWORD" \
  ${catalog_extra[@]+"${catalog_extra[@]}"}

apply_secret user-api-secret app=user-api \
  --from-literal=ConnectionStrings__DefaultConnection="$(sql_connection UsuariosDb)" \
  --from-literal=Keycloak__ClientSecret="$KEYCLOAK_CLIENT_SECRET" \
  --from-literal=MongoDb__Username="$MONGO_INITDB_ROOT_USERNAME" \
  --from-literal=MongoDb__Password="$MONGO_INITDB_ROOT_PASSWORD"

apply_secret payment-api-secret app=payment-api \
  --from-literal=MongoDb__Username="$MONGO_INITDB_ROOT_USERNAME" \
  --from-literal=MongoDb__Password="$MONGO_INITDB_ROOT_PASSWORD"

apply_secret notification-api-secret app=notification-api
