# Relatório de Entrega — Tech Challenge Fase 4

**FIAP Cloud Games (FCG)** · Pós-Tech FIAP · entrega de «DATA»

> Campos entre «aspas angulares» são os que faltam preencher.

---

## 1. Grupo

| Nome | Username no Discord |
|---|---|
| Bruno Mateus da Rocha | «discord» |
| Matheus Carvalho Miranda Holanda | «discord» |
| Lucas Bastos Delcico | «discord» |

## 2. Links

| Item | Link |
|---|---|
| **Vídeo "Pitch Final"** (até 25 min) | «link do YouTube ou Drive» |
| **Documentação principal** (README detalhado) | [FIAP.Orchestration/README.md](README.md) |
| Repositório de infraestrutura e orquestração | https://github.com/Projeto-Pos-Tech-FIAP/FIAP.Orchestration |
| Repositório — UsersAPI | https://github.com/Projeto-Pos-Tech-FIAP/FIAP.UsersAPI |
| Repositório — CatalogAPI | https://github.com/Projeto-Pos-Tech-FIAP/FIAP.CatalogAPI |
| Repositório — PaymentAPI | https://github.com/Projeto-Pos-Tech-FIAP/FIAP.PaymentAPI |
| Repositório — NotificationsAPI | https://github.com/Projeto-Pos-Tech-FIAP/FIAP.NotificationsAPI |

## 3. Requisitos da fase e onde cada um está

### 3.1 Infraestrutura gerenciada e portabilidade

| Exigência | Status | Onde está |
|---|---|---|
| Provedor de nuvem | **Azure** | Subscription *Azure for Students*, região `brazilsouth` |
| Cluster Kubernetes gerenciado (AKS) | ✅ | `aks-fcg-prod` no resource group `rg-fcg-prod` — Kubernetes 1.36, tier Free, 2 nós `Standard_D2as_v4`, Entra ID com Azure RBAC. Provisionado por [`scripts/azure-provision.sh`](scripts/azure-provision.sh) |
| Registry privado nativo da cloud (ACR) | ✅ | `acrfcgprod2046.azurecr.io`, sku Basic, `admin-enabled false`. Anexado ao AKS (`--attach-acr`), então o kubelet puxa imagem por identidade e **não existe `imagePullSecret` no cluster** |
| Exposição externa via Load Balancer | ⚠️ **no primeiro deploy** | [`environments/production/kustomization.yaml`](environments/production/kustomization.yaml) põe o `kong-proxy` como `type: LoadBalancer`; o IP público é atribuído quando o Service sobe |
| Manifestos de infraestrutura versionados | ✅ | [`k8s/`](k8s/) com Kustomize + overlay [`environments/production/`](environments/production/) |
| Documentação | ✅ | [README § 15 — Infraestrutura Gerenciada no Azure](README.md#15-infraestrutura-gerenciada-no-azure--aks-e-acr) |

### 3.2 Persistência poliglota e alta performance

| Exigência | Status | Onde está |
|---|---|---|
| NoSQL com driver oficial (`MongoDB.Driver` 3.8) | ✅ | Catalog, Users e Payment — `src/*/Infrastructure/Data/Mongo/MongoContext.cs` |
| Cenário de uso do NoSQL | ✅ | Logs de eventos do fluxo de compra (`FcgEvents.EventLogs`) e auditoria; consulta por `GET /api/eventlog/{correlationId}` |
| Cache distribuído (`IDistributedCache` + `StackExchange.Redis`) | ✅ | `src/*/Infrastructure/Caching/RedisCacheService.cs` em Catalog e Users |
| Cenário de uso do cache | ✅ | Catalog: `GET /api/game/{id}` e lista de jogos, com invalidação por prefixo na escrita. Users: token de serviço do Keycloak (dado de sessão) compartilhado entre réplicas, com L1 local |
| Documentação | ✅ | [README § 12 — Persistência Poliglota](README.md#12-persistência-poliglota--mongodb-e-redis) |

### 3.3 Busca avançada com Elasticsearch

| Exigência | Status | Onde está |
|---|---|---|
| Motor independente do banco relacional | ✅ | `ElasticGameSearchService` lê do índice `games`, não do SQL Server |
| Endpoint de busca | ✅ | `GET /api/search` — `SearchController` na CatalogAPI |
| Fuzzy search | ✅ | `multi_match` com `fuzziness: AUTO` e `fuzzy_transpositions` |
| Ordenação por relevância | ✅ | `_score` do Elasticsearch; `match_phrase` no título com `boost: 6` põe o acerto exato acima do aproximado |
| Sincronização na escrita | ✅ | `GameService`: POST/PUT reindexam e DELETE remove, com `refresh=true`; `POST /api/search/reindex` reconcilia o índice |
| Serviço gerenciado (OpenSearch / Elastic Cloud) | ⚠️ **opcional** | Cluster roda in-cluster ([`k8s/infrastructure/elasticsearch-deployment.yaml`](k8s/infrastructure/elasticsearch-deployment.yaml)). Apontar para Elastic Cloud é mudança de configuração, não de código: `Elasticsearch__Uri` no ConfigMap + `ELASTICSEARCH_API_KEY` no `.env` |
| Documentação | ✅ | [README § 14 — Busca Avançada](README.md#14-busca-avançada--elasticsearch) |

### 3.4 Automação de CI/CD e GitOps

| Exigência | Status | Onde está |
|---|---|---|
| Ferramenta | ✅ | GitHub Actions |
| Escopo mínimo (UsersAPI e CatalogAPI) | ✅ | Os **quatro** serviços têm `.github/workflows/ci-cd.yml` chamando o pipeline reutilizável [`dotnet-service.yml`](.github/workflows/dotnet-service.yml) |
| Build & Test | ✅ | `dotnet build` + `dotnet test` com resumo e artefato de resultados |
| Containerização com versionamento | ✅ | `docker/metadata-action` gera tags por SHA e por `v*.*.*` |
| Security scan (desejável) | ✅ | Trivy com SARIF no GitHub Security e gate em `CRITICAL` |
| Push para o registry | ✅ | ACR por OIDC quando `ACR_LOGIN_SERVER` está definida; GHCR como transição |
| Deploy sem downtime (Rolling Update) | ⚠️ **a validar** | Manifestos com `maxUnavailable: 0` e [`deploy-production.yml`](.github/workflows/deploy-production.yml) em `ubuntu-latest` com `az aks get-credentials`; falta a primeira execução contra o AKS |
| Documentação | ✅ | [README § 13 — CI/CD e GitOps](README.md#13-cicd-e-gitops-github-actions) |

### 3.5 Segurança e gestão de segredos

| Exigência | Status | Onde está |
|---|---|---|
| Zero hardcoded credentials | ✅ | Os cinco repositórios limpos — nenhuma connection string, senha ou client secret em código ou YAML |
| Injeção via Secrets do Kubernetes | ✅ | [`scripts/create-k8s-secrets.sh`](scripts/create-k8s-secrets.sh) cria `infra-secret` e os `*-api-secret`; os pods leem por `envFrom`/`secretKeyRef` |
| Credencial de nuvem na pipeline | ✅ | **Nenhuma**: GitHub Actions autentica no Azure por OIDC com federated credentials, sem client secret e sem `KUBE_CONFIG` |
| Nenhum Secret versionado | ✅ | Nenhum `kind: Secret` com dados reais no Git; desenvolvimento local usa User Secrets e `.env` fora do repositório |
| Documentação | ✅ | [README — Gestão de Segredos](README.md#gestão-de-segredos) |

## 4. Roteiro do vídeo (até 25 min)

Os quatro itens exigidos pelo enunciado, na ordem sugerida:

1. **Infraestrutura na nuvem** — painel do provedor com o cluster gerenciado e `kubectl get pods -n fiap-games` mostrando os pods de pé.
2. **Live deploy** — alterar o código, `git push` na `main` e acompanhar a pipeline promovendo a imagem e atualizando produção sem downtime:
   ```bash
   kubectl get pods -n fiap-games -w
   kubectl rollout status deployment/catalog-api -n fiap-games
   ```
3. **Busca avançada e impacto do cache**:
   ```bash
   curl -s "$GW/api/search?q=couter%20strke" | jq '.hits[] | {title, score}'   # fuzzy + relevância
   time curl -s "$GW/api/game/1" -H "Authorization: Bearer $TOKEN"             # 1ª chamada: banco
   time curl -s "$GW/api/game/1" -H "Authorization: Bearer $TOKEN"             # 2ª chamada: Redis
   ```
4. **NoSQL na arquitetura** — explicar o log de eventos do fluxo de compra e mostrar:
   ```bash
   curl -s "$GW/api/eventlog/$CORRELATION_ID" -H "Authorization: Bearer $TOKEN" | jq
   ```

## 5. Pendências conhecidas

Em ordem de bloqueio:

1. **`ORCHESTRATION_TOKEN` sem permissão de escrita** — o job *Promote to production (GitOps)* falha com `403` ao atualizar a tag no FIAP.Orchestration. Precisa de um PAT com `Contents: Read and write` nos quatro repositórios de API; o GitHub só emite PAT pela interface web. Enquanto isso, a `main` não reflete produção e o live deploy não roda de ponta a ponta.
2. **Primeiro deploy de verdade** — rodar o `deploy-production` contra o AKS e conferir o rolling update sem downtime e o IP do Load Balancer.
3. **Vídeo e os três campos deste relatório** — a parte do live deploy por `git push` depende do item 1.

Já feitos: infraestrutura provisionada no Azure, as seis Variables definidas nos cinco repositórios, imagens no ACR e os Secrets da aplicação criados no cluster a partir do `.env` (credenciais geradas, nunca versionadas).

> O custo roda sobre o crédito da *Azure for Students*. Para pausar: `az aks stop -g rg-fcg-prod -n aks-fcg-prod`. Para encerrar: `az group delete --name rg-fcg-prod --yes`.
