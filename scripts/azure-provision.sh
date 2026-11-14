#!/usr/bin/env bash
# Provisiona a infraestrutura gerenciada da FCG no Azure: AKS + ACR + a
# identidade que o GitHub Actions usa para publicar imagem e aplicar manifesto.
#
# Idempotente: cada recurso é criado só se não existir, então reexecutar é seguro.
#
# ATENÇÃO — ISTO GERA CUSTO NA SUBSCRIPTION. Com os valores padrão (2 nós
# Standard_B2s, ACR Basic, 1 Load Balancer público) a ordem de grandeza é de
# algumas dezenas de dólares por mês. O control plane do AKS no tier Free não é
# cobrado; os nós, o disco, o Load Balancer e o tráfego são. Rode `az aks delete`
# e `az group delete` quando não estiver usando.
#
# Pré-requisitos: az CLI instalada e `az login` feito pelo usuário.
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-fcg-prod}"
LOCATION="${LOCATION:-brazilsouth}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-fcg-prod}"
ACR_NAME="${ACR_NAME:-}"                       # precisa ser único no Azure inteiro
NODE_COUNT="${NODE_COUNT:-2}"
NODE_SIZE="${NODE_SIZE:-Standard_B2s}"
K8S_NAMESPACE="${K8S_NAMESPACE:-fiap-games}"
IDENTITY_NAME="${IDENTITY_NAME:-id-fcg-github-actions}"
GITHUB_ORG="${GITHUB_ORG:-Projeto-Pos-Tech-FIAP}"
GITHUB_REPOS="${GITHUB_REPOS:-FIAP.UsersAPI FIAP.CatalogAPI FIAP.PaymentAPI FIAP.NotificationsAPI}"
ORCHESTRATION_REPO="${ORCHESTRATION_REPO:-FIAP.Orchestration}"

if [ -z "$ACR_NAME" ]; then
  echo "ERRO: defina ACR_NAME (5-50 caracteres alfanuméricos, único no Azure)." >&2
  echo "      ex.: ACR_NAME=acrfcg$RANDOM bash scripts/azure-provision.sh" >&2
  exit 1
fi

command -v az > /dev/null || { echo "ERRO: az CLI não encontrada." >&2; exit 1; }
az account show > /dev/null 2>&1 || { echo "ERRO: rode 'az login' primeiro." >&2; exit 1; }

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "Subscription: $(az account show --query name -o tsv)"
echo "Região: $LOCATION · Resource group: $RESOURCE_GROUP"
echo

exists() { az "$@" > /dev/null 2>&1; }

# ─── Resource group ──────────────────────────────────────────────────────────
if exists group show --name "$RESOURCE_GROUP"; then
  echo "✓ Resource group $RESOURCE_GROUP já existe"
else
  echo "→ Criando resource group $RESOURCE_GROUP"
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none
fi

# ─── ACR — registry privado nativo da cloud ──────────────────────────────────
if exists acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP"; then
  echo "✓ ACR $ACR_NAME já existe"
else
  echo "→ Criando ACR $ACR_NAME (sku Basic)"
  # admin-enabled=false: o acesso é por identidade (OIDC/managed identity), nunca
  # por usuário e senha do registry.
  az acr create --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" \
    --sku Basic --admin-enabled false -o none
fi
ACR_LOGIN_SERVER="$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query loginServer -o tsv)"
ACR_ID="$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)"

# ─── AKS — Kubernetes gerenciado ─────────────────────────────────────────────
if exists aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP"; then
  echo "✓ AKS $CLUSTER_NAME já existe"
else
  echo "→ Criando AKS $CLUSTER_NAME ($NODE_COUNT x $NODE_SIZE) — leva ~5 min"
  # --attach-acr dá AcrPull à identidade do kubelet: os pods puxam imagem do ACR
  # sem imagePullSecret nenhum no cluster.
  # --enable-managed-identity + --enable-aad + RBAC do Azure: autorização do
  # cluster vem do Entra ID, sem kubeconfig com certificado de admin circulando.
  az aks create \
    --name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --tier free \
    --node-count "$NODE_COUNT" \
    --node-vm-size "$NODE_SIZE" \
    --enable-managed-identity \
    --enable-aad \
    --enable-azure-rbac \
    --attach-acr "$ACR_NAME" \
    --network-plugin azure \
    --generate-ssh-keys \
    -o none
fi
CLUSTER_ID="$(az aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)"

# ─── Identidade do GitHub Actions (OIDC, sem segredo) ────────────────────────
# Managed identity em vez de app registration: não exige permissão de criar
# aplicativo no Entra ID, e a federação com o GitHub dispensa client secret —
# nenhuma credencial de nuvem fica guardada no GitHub.
if exists identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP"; then
  echo "✓ Managed identity $IDENTITY_NAME já existe"
else
  echo "→ Criando managed identity $IDENTITY_NAME"
  az identity create --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" -o none
fi
CLIENT_ID="$(az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query clientId -o tsv)"
PRINCIPAL_ID="$(az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query principalId -o tsv)"

add_federation() {
  local name="$1" subject="$2"
  if exists identity federated-credential show --name "$name" \
      --identity-name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP"; then
    echo "✓ Federação $name já existe"
  else
    echo "→ Federando $subject"
    az identity federated-credential create \
      --name "$name" \
      --identity-name "$IDENTITY_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --issuer "https://token.actions.githubusercontent.com" \
      --subject "$subject" \
      --audiences "api://AzureADTokenExchange" -o none
  fi
}

# Um federated credential por repositório: o subject do token do GitHub carrega
# o repo e a ref, e o Azure só troca o token se casar exatamente.
for repo in $GITHUB_REPOS; do
  add_federation "gh-$(echo "$repo" | tr '[:upper:].' '[:lower:]-')-main" \
    "repo:${GITHUB_ORG}/${repo}:ref:refs/heads/main"
done
add_federation "gh-orchestration-production" \
  "repo:${GITHUB_ORG}/${ORCHESTRATION_REPO}:environment:production"

assign_role() {
  local role="$1" scope="$2"
  if az role assignment list --assignee-object-id "$PRINCIPAL_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" --query '[0].id' -o tsv | grep -q .; then
    echo "✓ Role '$role' já atribuída"
  else
    echo "→ Atribuindo '$role'"
    az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" -o none
  fi
}

# AcrPush: publicar imagem. Cluster User: obter o kubeconfig.
# RBAC Writer: aplicar manifesto no namespace da aplicação — não é Admin, então
# a pipeline não consegue mexer em RBAC do cluster.
assign_role "AcrPush" "$ACR_ID"
assign_role "Azure Kubernetes Service Cluster User Role" "$CLUSTER_ID"
assign_role "Azure Kubernetes Service RBAC Writer" "$CLUSTER_ID/namespaces/$K8S_NAMESPACE"

# ─── Saída: o que configurar no GitHub ───────────────────────────────────────
cat <<SUMMARY

════════════════════════════════════════════════════════════════════════════
Infraestrutura pronta.

Variables (Settings › Secrets and variables › Actions › Variables) — nenhum
segredo: com OIDC não existe senha a guardar. Defina no nível da organização
para valerem nos cinco repositórios de uma vez.

  ACR_LOGIN_SERVER       $ACR_LOGIN_SERVER
  AZURE_CLIENT_ID        $CLIENT_ID
  AZURE_TENANT_ID        $TENANT_ID
  AZURE_SUBSCRIPTION_ID  $SUBSCRIPTION_ID
  AKS_RESOURCE_GROUP     $RESOURCE_GROUP
  AKS_CLUSTER_NAME       $CLUSTER_NAME

Pela CLI, no nível da organização:

  gh variable set ACR_LOGIN_SERVER      --org $GITHUB_ORG --body "$ACR_LOGIN_SERVER"
  gh variable set AZURE_CLIENT_ID       --org $GITHUB_ORG --body "$CLIENT_ID"
  gh variable set AZURE_TENANT_ID       --org $GITHUB_ORG --body "$TENANT_ID"
  gh variable set AZURE_SUBSCRIPTION_ID --org $GITHUB_ORG --body "$SUBSCRIPTION_ID"
  gh variable set AKS_RESOURCE_GROUP    --org $GITHUB_ORG --body "$RESOURCE_GROUP"
  gh variable set AKS_CLUSTER_NAME      --org $GITHUB_ORG --body "$CLUSTER_NAME"

Depois, para trabalhar no cluster da sua máquina:

  az aks get-credentials -g $RESOURCE_GROUP -n $CLUSTER_NAME
  kubectl get nodes

E para desligar tudo e parar o custo:

  az group delete --name $RESOURCE_GROUP --yes
════════════════════════════════════════════════════════════════════════════
SUMMARY
