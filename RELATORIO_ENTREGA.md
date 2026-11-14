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
| Cluster Kubernetes gerenciado (EKS/AKS/GKE/OKE) | ⚠️ **pendente** | «provedor, região e nome do cluster» |
| Registry privado nativo da cloud | ⚠️ **pendente** | Hoje as imagens vão para o GHCR (`ghcr.io/projeto-pos-tech-fiap/*`), definido em [`environments/production/kustomization.yaml`](environments/production/kustomization.yaml) |
| Exposição externa via Load Balancer ou Ingress | ⚠️ **pendente** | Kong é o único ponto de entrada ([`k8s/gateway/`](k8s/gateway/)), hoje como `NodePort 30080` |
| Manifestos de infraestrutura versionados | ✅ | [`k8s/`](k8s/) com Kustomize + overlay [`environments/production/`](environments/production/) |

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
| Serviço gerenciado (OpenSearch / Elastic Cloud) | ⚠️ **pendente** | Cluster roda in-cluster ([`k8s/infrastructure/elasticsearch-deployment.yaml`](k8s/infrastructure/elasticsearch-deployment.yaml)); `Elasticsearch__Uri` + `Elasticsearch__ApiKey` já permitem apontar para endpoint gerenciado sem mudar imagem |
| Documentação | ✅ | [README § 14 — Busca Avançada](README.md#14-busca-avançada--elasticsearch) |

### 3.4 Automação de CI/CD e GitOps

| Exigência | Status | Onde está |
|---|---|---|
| Ferramenta | ✅ | GitHub Actions |
| Escopo mínimo (UsersAPI e CatalogAPI) | ✅ | Os **quatro** serviços têm `.github/workflows/ci-cd.yml` chamando o pipeline reutilizável [`dotnet-service.yml`](.github/workflows/dotnet-service.yml) |
| Build & Test | ✅ | `dotnet build` + `dotnet test` com resumo e artefato de resultados |
| Containerização com versionamento | ✅ | `docker/metadata-action` gera tags por SHA e por `v*.*.*` |
| Security scan (desejável) | ✅ | Trivy com SARIF no GitHub Security e gate em `CRITICAL` |
| Push para o registry | ✅ | GHCR (ver 3.1 — registry da cloud pendente) |
| Deploy sem downtime (Rolling Update) | ⚠️ **parcial** | Manifestos com `maxUnavailable: 0` e [`deploy-production.yml`](.github/workflows/deploy-production.yml) prontos; o job nunca concluiu — ver § 5 |
| Documentação | ✅ | [README § 13 — CI/CD e GitOps](README.md#13-cicd-e-gitops-github-actions) |

### 3.5 Segurança e gestão de segredos

| Exigência | Status | Onde está |
|---|---|---|
| Zero hardcoded credentials | ⚠️ **parcial** | Orchestration e Catalog já limpos; PRs abertos em Users (#3), Payment (#3) e Notifications (#2) |
| Injeção via Secrets do Kubernetes | ✅ | [`scripts/create-k8s-secrets.sh`](scripts/create-k8s-secrets.sh) cria `infra-secret` e os `*-api-secret`; os pods leem por `envFrom`/`secretKeyRef` |
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

1. **`ORCHESTRATION_TOKEN` sem permissão de escrita** — o job *Promote to production (GitOps)* falha com `403` ao atualizar a tag no FIAP.Orchestration. Precisa de um PAT com `Contents: Read and write` nos quatro repositórios de API. Enquanto isso, a `main` não reflete produção e o live deploy não roda de ponta a ponta.
2. **Cluster gerenciado na cloud** — hoje o ambiente é minikube local; falta provisionar EKS/AKS/GKE/OKE, trocar o registry para o nativo da cloud e expor o Kong por Load Balancer/Ingress.
3. **Runner e segredos do deploy** — `deploy-production.yml` roda em `self-hosted` (variável `DEPLOY_RUNS_ON`), e o repositório não tem `KUBE_CONFIG` nem os segredos de aplicação configurados.
4. **PRs de gestão de segredos** abertos em UsersAPI (#3), PaymentAPI (#3) e NotificationsAPI (#2).
5. **Vídeo e preenchimento deste relatório** — depende dos itens 1 a 3 para a parte do live deploy.
