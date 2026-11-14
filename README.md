# FIAP.Orchestration

Repositório central de infraestrutura da **FIAP Games Platform** — contém o `docker-compose.yml` para desenvolvimento local e os manifestos Kubernetes para orquestração em cluster.

---

## Índice

1. [Visão Geral da Plataforma](#1-visão-geral-da-plataforma)
2. [Estrutura de Repositórios](#2-estrutura-de-repositórios)
3. [Arquitetura Clean Architecture — CatalogAPI](#3-arquitetura-clean-architecture--catalogapi)
4. [Fluxo de Compra via Kafka](#4-fluxo-de-compra-via-kafka)
5. [Containerização com Docker](#5-containerização-com-docker)
6. [Orquestração com Kubernetes](#6-orquestração-com-kubernetes)
7. [Por que Deployment, Service e PVC?](#7-por-que-deployment-service-e-pvc)
8. [Como Executar — Docker Compose](#8-como-executar--docker-compose)
9. [Como Executar — Kubernetes](#9-como-executar--kubernetes)
10. [API Gateway (Kong)](#10-api-gateway-kong)
11. [Observabilidade (Prometheus + Grafana)](#11-observabilidade-prometheus--grafana)
12. [Persistência Poliglota — MongoDB e Redis](#12-persistência-poliglota--mongodb-e-redis)
13. [CI/CD e GitOps (GitHub Actions)](#13-cicd-e-gitops-github-actions)
14. [Busca Avançada — Elasticsearch](#14-busca-avançada--elasticsearch)
15. [Infraestrutura Gerenciada no Azure — AKS e ACR](#15-infraestrutura-gerenciada-no-azure--aks-e-acr)
16. [Próximos Passos](#16-próximos-passos)

---

## 1. Visão Geral da Plataforma

A plataforma FIAP Games é composta por quatro microserviços que se comunicam via **Apache Kafka**, com infraestrutura de suporte centralizada (SQL Server, MongoDB, Redis e Elasticsearch).

```
┌─────────────────────────────────────────────────────────────────┐
│                    FIAP Games Platform                          │
│                                                                 │
│  ┌──────────────┐     ┌──────────────┐     ┌────────────────┐  │
│  │  CatalogAPI  │────▶│    Kafka     │────▶│  PaymentAPI    │  │
│  │  :5001/8080  │     │  :9092       │     │  :5003/8080    │  │
│  └──────┬───────┘     └──────┬───────┘     └───────┬────────┘  │
│         │                   │                      │           │
│         ▼                   ▼                      ▼           │
│  ┌──────────────┐     ┌──────────────┐     ┌────────────────┐  │
│  │   UserAPI    │     │NotificationAPI│    │   SQL Server   │  │
│  │  :5002/8080  │     │  :5004/8080  │     │  MongoDB/Redis │  │
│  └──────────────┘     └──────────────┘     └────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Stack Tecnológica

| Tecnologia | Versão | Uso |
|---|---|---|
| .NET / ASP.NET Core | 10.0 | Runtime de todos os microserviços |
| Entity Framework Core | 10.0 | ORM — SQL Server |
| AutoMapper | 12.0.1 | Mapeamento Entity ↔ DTO |
| Confluent.Kafka | 2.x | Producer/Consumer Kafka |
| MongoDB.Driver | 3.x | NoSQL — logs de eventos de integração e audit logs |
| StackExchange.Redis / IDistributedCache | 2.x | Cache distribuído — sessões e consultas onerosas |
| Docker | — | Containerização |
| Kubernetes | 1.28+ | Orquestração de containers |
| Kustomize | — | Composição de manifestos K8s |

---

## 2. Estrutura de Repositórios

```
source/repos/
│
├── FIAP.CatalogAPI/               ← Microserviço de catálogo
│   ├── src/
│   │   ├── FIAP.CatalogAPI.Domain/
│   │   ├── FIAP.CatalogAPI.Application/
│   │   ├── FIAP.CatalogAPI.Infrastructure/
│   │   ├── FIAP.CatalogAPI.Api/
│   │   └── FIAP.CatalogAPI.Tests/
│   ├── k8s/                       ← Manifestos K8s do próprio serviço
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── Dockerfile                 ← Multi-stage build
│   └── .dockerignore
│
└── FIAP.Orchestration/            ← Este repositório (infraestrutura)
    ├── docker-compose.yml         ← Stack completa local
    ├── scripts/
    │   ├── configure-kong-jwt.sh  ← Injeta a chave pública do Keycloak no Kong
    │   └── create-k8s-secrets.sh  ← Cria os Secrets no cluster a partir do .env
    └── k8s/
        ├── 00-namespace.yaml
        ├── kustomization.yaml     ← Aplica tudo com 1 comando
        ├── configmaps/            ← Dados não-sensíveis
        ├── infrastructure/        ← SQL, Mongo, Redis, Kafka, Keycloak
        ├── services/              ← Todos os microserviços
        ├── monitoring/            ← Prometheus + Grafana
        └── gateway/               ← Kong API Gateway (único ponto de entrada)
```

> **Princípio:** cada repositório de serviço possui seu próprio `k8s/` com os manifestos específicos. O `FIAP.Orchestration` centraliza a infraestrutura compartilhada sem duplicar código de negócio.

---

## 3. Arquitetura Clean Architecture — CatalogAPI

```
┌──────────────────────────────────────────────────────────┐
│                    CatalogAPI.Api                        │
│   GameController · PurchaseController · ExceptionMiddle  │
└─────────────────────────┬────────────────────────────────┘
                          │ usa
┌─────────────────────────▼────────────────────────────────┐
│                CatalogAPI.Application                    │
│   IGameService · IPurchaseService · IKafkaProducerService│
│   GameService  · PurchaseService  · DTOs · AutoMapper    │
└──────────────┬──────────────────────────────┬────────────┘
               │ usa                          │ depende de
┌──────────────▼──────────┐   ┌───────────────▼────────────┐
│   CatalogAPI.Domain     │   │  CatalogAPI.Infrastructure  │
│   Entities · Events     │   │  EF Core · Repositories     │
│   Interfaces · Exceptions│  │  MongoAuditService · Kafka  │
└─────────────────────────┘   └─────────────────────────────┘
```

| Projeto | Responsabilidade | Dependências externas |
|---|---|---|
| `Domain` | Entidades, interfaces de repositório, eventos de domínio, exceções | Nenhuma |
| `Application` | Serviços de aplicação, DTOs, mapeamentos AutoMapper | AutoMapper, DI.Abstractions |
| `Infrastructure` | EF Core + SQL Server, MongoDB audit, Kafka producer/consumer, Repositórios | EF Core, MongoDB.Driver, Confluent.Kafka |
| `Api` | Controllers REST, middleware global de exceções, Swagger | Swashbuckle, ASP.NET Core |
| `Tests` | Testes unitários (14 testes, 100% passando) | xUnit, Moq, FluentAssertions |

---

## 4. Fluxo de Compra via Kafka

```
Cliente                 CatalogAPI              Kafka               PaymentAPI
   │                       │                      │                      │
   │  POST /api/purchase   │                      │                      │
   │──────────────────────▶│                      │                      │
   │                       │  Valida jogo + preço │                      │
   │                       │  Gera CorrelationId  │                      │
   │                       │─── OrderPlacedEvent ─▶│                      │
   │                       │   { UserId, GameId,  │                      │
   │                       │     Price, CorrId }  │                      │
   │  202 Accepted         │                      │                      │
   │◀──────────────────────│                      │                      │
   │  { CorrelationId }    │                      │──────────────────────▶│
   │                       │                      │  consome order-placed │
   │                       │                      │  processa pagamento   │
   │                       │                      │◀──────────────────────│
   │                       │◀── PaymentProcessed ─│  publica resultado    │
   │                       │   { CorrId, Status } │                      │
   │                       │  Se Approved:         │                      │
   │                       │  Cria Library +       │                      │
   │                       │  Adiciona LibraryGame │                      │
```

### Tópicos Kafka

| Tópico | Publicado por | Consumido por | Payload |
|---|---|---|---|
| `order-placed` | CatalogAPI | PaymentAPI | `{ UserId, GameId, Price, CorrelationId }` |
| `payment-processed` | PaymentAPI | CatalogAPI | `{ CorrelationId, UserId, GameId, Status, Reason }` |
| `user-created` | UserAPI | CatalogAPI | `{ UserId, Email, Name }` |
| `notification-requested` | PaymentAPI / CatalogAPI | NotificationAPI | `{ UserId, Type, Message }` |

O `PaymentProcessedConsumer` é um `BackgroundService` com **manual commit** — o offset só avança após processamento bem-sucedido, garantindo que nenhuma mensagem seja perdida em caso de falha.

---

## 5. Containerização com Docker

O Dockerfile usa **multi-stage build** para reduzir a imagem final de ~600MB para ~100MB:

```dockerfile
# Stage 1: SDK — compila e publica
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Copia só os .csproj primeiro → layer cache para restore
COPY src/.../*.csproj ...
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app/publish /p:UseAppHost=false

# Stage 2: Runtime — apenas o necessário para executar
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
RUN adduser --system appuser
USER appuser
COPY --from=build /app/publish .
EXPOSE 8080
ENTRYPOINT ["dotnet", "FIAP.CatalogAPI.Api.dll"]
```

| Stage | Imagem base | Tamanho | Finalidade |
|---|---|---|---|
| `build` | dotnet/sdk:10.0 | ~600MB | Compilar e publicar |
| `final` | dotnet/aspnet:10.0 | ~80MB | Executar em produção |

**Boas práticas aplicadas:** cache de layers (copia `.csproj` antes do source), `.dockerignore` excluindo `bin/` e `obj/`, usuário não-root, `UseAppHost=false`.

---

## 6. Orquestração com Kubernetes

Todos os recursos são criados no namespace `fiap-games`.

### Separação ConfigMap vs Secret

| Tipo | O que armazena | Exemplos |
|---|---|---|
| `ConfigMap` | Dados não-sensíveis, configurações de comportamento | Tópicos Kafka, hostname do MongoDB, GroupId |
| `Secret` | Dados sensíveis, credenciais, connection strings | Senha do SQL Server, connection string completa |

### Hierarquia de ConfigMaps por Pod

```
Pod catalog-api
├── envFrom: shared-infra-config    ← Kafka topics, Redis, MongoDB host (TODOS usam)
├── envFrom: catalog-api-config     ← GroupId e DatabaseName específicos do serviço
└── envFrom: catalog-api-secret     ← Connection string SQL, senhas (Secret)
```

### Comunicação Entre Serviços no Cluster

Dentro do cluster, os pods se comunicam pelos **nomes dos Services** como DNS — sem IPs:

| De | Para | URL usada |
|---|---|---|
| CatalogAPI | Kafka | `kafka:9092` |
| CatalogAPI | SQL Server | `sqlserver:1433` |
| CatalogAPI | MongoDB | `mongodb:27017` |
| PaymentAPI | CatalogAPI | `http://catalog-api:80` |
| UserAPI | CatalogAPI | `http://catalog-api:80` |

> Os Services usam `type: ClusterIP` (apenas internos ao cluster). Para expor externamente, adicione um `Ingress` com Nginx ou Traefik, ou mude para `type: NodePort` em ambientes locais.

---

## 7. Por que Deployment, Service e PVC?

Cada arquivo resolve uma camada diferente e fundamental no Kubernetes.

### `deployment.yaml` — Quem garante que sua aplicação está viva?

Sem um Deployment, você criaria Pods manualmente. O problema: **Pods são descartáveis**. Se um Pod crasha, ele morre e não volta.

O Deployment é o *controlador* que responde a:
- Quantas instâncias devem estar rodando? (`replicas: 2`)
- O que fazer se um Pod morrer? → Recria automaticamente
- Como atualizar sem downtime? → Rolling update (sobe o novo antes de derrubar o velho)
- E se a nova versão quebrar? → `kubectl rollout undo deployment/catalog-api`

```
Deployment "catalog-api"
  ├── Pod 1 (rodando) ✅
  ├── Pod 2 (morreu) ❌  ← Deployment detecta e recria automaticamente
  └── Pod 2 (recriado) ✅
```

**Sem Deployment:** você gerencia Pods na mão. Em produção, isso não escala.

---

### `service.yaml` — Como os outros serviços encontram sua aplicação?

Cada Pod recebe um IP **temporário e aleatório**. Quando é recriado (pelo Deployment), ganha um IP diferente. Se o `user-api` chamasse o `catalog-api` pelo IP do Pod, quebraria a cada restart.

O Service resolve isso de duas formas:

1. **DNS estável:** cria um nome fixo (`catalog-api`) que nunca muda
2. **Load balancer interno:** se há 2 réplicas, o Service distribui as requisições automaticamente

```
user-api chama → http://catalog-api:80
                        ↓
                 Service "catalog-api"
                  ├── redireciona para Pod 1 (IP: 10.1.0.45)
                  └── redireciona para Pod 2 (IP: 10.1.0.67)
```

É por isso que no `appsettings.json` de K8s você coloca `kafka:9092` em vez de um IP.

**Sem Service:** os Pods ficam isolados, ninguém consegue chamá-los de forma confiável.

---

### `pvc.yaml` — Onde ficam os dados quando o Pod reinicia?

O sistema de arquivos de um container é **efêmero** — quando o Pod morre, tudo que foi escrito no disco some junto. Para um banco de dados, isso seria catastrófico.

O PVC (PersistentVolumeClaim) é um pedido de armazenamento durável:

```
PVC "sqlserver-pvc" (10Gi)
  └── montado em /var/opt/mssql no container do SQL Server

  Pod do SQL Server morre e é recriado
       ↓
  Novo Pod monta o mesmo PVC — dados intactos ✅
```

**Sem PVC:** todo restart do banco de dados apagaria todos os dados. Viável para cache (Redis pode viver sem), inaceitável para SQL Server e MongoDB.

---

### Resumo Visual

```
┌─────────────────────────────────────────────────────┐
│                   Kubernetes Node                    │
│                                                     │
│  deployment.yaml          service.yaml              │
│  ┌─────────────┐         ┌──────────────┐           │
│  │  Deployment │──cria──▶│     Pod 1    │◀──────┐  │
│  │  (garante   │         └──────────────┘       │  │
│  │  N réplicas │──cria──▶┌──────────────┐    Service│
│  │  + updates) │         │     Pod 2    │◀──(DNS+LB)│
│  └─────────────┘         └──────┬───────┘       │  │
│                                 │             outros │
│  pvc.yaml                       │              pods  │
│  ┌─────────────┐                │                   │
│  │    PVC      │◀───monta───────┘                   │
│  │ (disco que  │                                    │
│  │  persiste)  │                                    │
│  └─────────────┘                                    │
└─────────────────────────────────────────────────────┘
```

Cada arquivo resolve uma camada: **ciclo de vida** (Deployment), **rede** (Service) e **armazenamento** (PVC).

---

## 8. Como Executar — Docker Compose

O `docker-compose.yml` sobe toda a stack com healthchecks e dependências corretas.

```bash
# 1. Entrar na pasta de orquestração
cd FIAP.Orchestration

# 2. Subir toda a stack (infra + CatalogAPI)
docker-compose up -d

# 3. Acompanhar os logs
docker-compose logs -f catalog-api

# 4. Verificar status de todos os containers
docker-compose ps

# 5. Parar tudo mantendo volumes
docker-compose down

# 6. Parar e remover volumes (reset completo)
docker-compose down -v
```

### Endereços Disponíveis

| Serviço | Endereço | Credenciais |
|---|---|---|
| CatalogAPI | http://localhost:5001/swagger | — |
| Kafka UI | http://localhost:8090 | — |
| SQL Server | localhost:1433 | `sa` / definida no `.env` |
| MongoDB | localhost:27018 | definidas no `.env` |
| Redis | localhost:6379 | sem autenticação |
| Kafka | localhost:9092 | bootstrap server |

> **Atenção:** o CatalogAPI aguarda SQL Server, MongoDB e Kafka estarem *healthy* antes de iniciar. Na primeira execução, o SQL Server pode demorar ~30s.

---

## 9. Como Executar — Kubernetes

**Pré-requisitos:** cluster local rodando (Docker Desktop com K8s, Kind, Minikube ou k3d) e `kubectl` configurado.

```bash
# Passo 1: Build da imagem do CatalogAPI
cd FIAP.CatalogAPI
docker build -t fiap/catalog-api:latest .

# Passo 2: Se usar Kind ou k3d, carregar a imagem no cluster
kind load docker-image fiap/catalog-api:latest
# ou para k3d:
k3d image import fiap/catalog-api:latest -c <nome-do-cluster>

# Passo 3: Criar os Secrets a partir do .env (copie o .env.example e troque os CHANGE_ME)
cd FIAP.Orchestration
bash scripts/create-k8s-secrets.sh

# Passo 4: Aplicar todos os manifestos com Kustomize
kubectl apply -k k8s/

# Passo 5: Aguardar pods iniciarem
kubectl get pods -n fiap-games -w

# Passo 6: Port-forward para acessar a API
kubectl port-forward svc/catalog-api 5001:80 -n fiap-games
# Abrir: http://localhost:5001/swagger
```

### Comandos Úteis

```bash
# Ver todos os recursos no namespace
kubectl get all -n fiap-games

# Ver logs de um pod
kubectl logs -f deployment/catalog-api -n fiap-games

# Descrever um pod com problema
kubectl describe pod <nome-do-pod> -n fiap-games

# Escalar para 3 réplicas
kubectl scale deployment/catalog-api --replicas=3 -n fiap-games

# Rolling update sem downtime
kubectl set image deployment/catalog-api catalog-api=fiap/catalog-api:v2 -n fiap-games

# Rollback
kubectl rollout undo deployment/catalog-api -n fiap-games

# Remover tudo
kubectl delete -k k8s/
```

> **Segredos:** nenhum manifesto versionado contém credenciais. Os Secrets do Kubernetes são criados à parte e injetados nos pods em tempo de execução — ver [Gestão de Segredos](#gestão-de-segredos).

### Gestão de Segredos

| Onde | Origem dos valores | Como chegam ao processo |
|---|---|---|
| Kubernetes (local) | `.env` fora do git → `bash scripts/create-k8s-secrets.sh` | `envFrom.secretRef` e `secretKeyRef` |
| Kubernetes (pipeline) | GitHub Secrets → step *Ensure application secrets* do `deploy-production.yml` | idem |
| Docker Compose | `.env` fora do git | interpolação `${VAR:?}`; o compose falha se faltar variável |
| `dotnet run` | [User Secrets](https://learn.microsoft.com/aspnet/core/security/app-secrets) de cada API | carregado automaticamente em `Development` |

O script cria `infra-secret`, `catalog-api-secret`, `user-api-secret`, `payment-api-secret` e `notification-api-secret` e pode ser reexecutado. Ele recusa valores `CHANGE_ME` e monta as connection strings a partir de `MSSQL_SA_PASSWORD`.

O client secret do Keycloak fica no realm como o placeholder `${KEYCLOAK_CLIENT_SECRET}`, resolvido pelo `--import-realm` a partir da variável de ambiente do container. A sonda do SQL Server lê a senha da variável do próprio container.

**Rotação de credenciais:** SQL Server, MongoDB, Postgres e o realm do Keycloak só leem esses valores ao inicializar um volume vazio. Para trocar uma senha com dados já existentes, altere-a também dentro do serviço; num ambiente descartável, basta apagar os PVCs e aplicar de novo.

---

## 10. API Gateway (Kong)

**Ferramenta escolhida: Kong API Gateway**, rodando em modo **DB-less** (sem banco de dados próprio — toda a configuração vive em um arquivo declarativo versionado neste repositório). É o único ponto de entrada externo do sistema FCG: `user-api` e `catalog-api` continuam com Service `ClusterIP`, inacessíveis diretamente de fora do cluster.

```
Cliente ──▶ Kong (NodePort :30080) ──┬──▶ user-api  (ClusterIP, sem acesso externo direto)
                                     └──▶ catalog-api (ClusterIP, sem acesso externo direto)
```

### Onde está a configuração

| Arquivo | Responsabilidade |
|---|---|
| [`k8s/gateway/kong-configmap.yaml`](k8s/gateway/kong-configmap.yaml) | `kong.yml` — declaração DB-less: services, routes, plugins e a credencial JWT do consumer (versionado) |
| [`k8s/gateway/kong-deployment.yaml`](k8s/gateway/kong-deployment.yaml) | Deployment do Kong (`KONG_DATABASE=off`, monta o `kong.yml`, `KONG_NGINX_WORKER_PROCESSES=1`) |
| [`k8s/gateway/kong-service.yaml`](k8s/gateway/kong-service.yaml) | `kong-proxy` (NodePort 30080 — entrada externa) e `kong-admin` (ClusterIP — Admin/Status API e Kong Manager, só internos) |
| [`scripts/configure-kong-jwt.sh`](scripts/configure-kong-jwt.sh) | Busca a chave pública real do Keycloak (JWKS) e substitui o placeholder no `kong-configmap.yaml` |

### Kong Manager — interface web

A imagem `kong:3.7` já traz o **Kong Manager OSS**, habilitado no Deployment por `KONG_ADMIN_GUI_LISTEN` (porta 8002) e `KONG_ADMIN_GUI_API_URL`. Em modo DB-less ele é **somente leitura**: lê a mesma configuração declarativa do `kong.yml` e serve para inspecionar services, routes, plugins e consumers sem depender de `curl` na Admin API.

Como o Manager roda no navegador e é ele quem chama a Admin API, os **dois** port-forwards são necessários:

```bash
kubectl port-forward -n fiap-games svc/kong-admin 8001:8001 8002:8002
# interface: http://localhost:8002
```

A porta 8002 fica no Service `kong-admin`, que é `ClusterIP` — o Manager e a Admin API nunca são expostos fora do cluster, só o `kong-proxy`.

### Rotas expostas pelo Gateway

| Método | Path | Backend | JWT exigido? |
|---|---|---|---|
| POST | `/api/auth/login` | user-api | **Não** — é como o cliente obtém o token |
| POST | `/api/auth/refresh` | user-api | **Não** |
| GET | `/api/users` | user-api | Sim (+ role `Admin` no token) |
| POST | `/api/users` | user-api | Sim (+ role `Admin`) |
| PUT | `/api/users/{userEmail}` | user-api | Sim (+ role `Admin`) |
| PUT | `/api/users/enable?userEmail=...&enable=...` | user-api | Sim (+ role `Admin`) |
| GET | `/api/users/search?username=...&email=...` | user-api | Sim (+ role `Admin`) |
| GET | `/api/game` | catalog-api | Sim |
| GET | `/api/game/{id}` | catalog-api | Sim |
| POST | `/api/game` | catalog-api | Sim |
| PUT | `/api/game/{id}` | catalog-api | Sim |
| DELETE | `/api/game/{id}` | catalog-api | Sim |
| POST | `/api/purchase` | catalog-api | Sim |
| GET | `/api/eventlog` | catalog-api | Sim |
| GET | `/api/eventlog/{correlationId}` | catalog-api | Sim |

`PaymentAPI` e `NotificationsAPI` não têm rota no Gateway — o desafio só pede roteamento explícito para `UsersAPI`/`CatalogAPI` (PaymentAPI reage via Kafka; NotificationsAPI virou Function serverless).

### Como o Gateway funciona

- **Recebe todas as requisições externas** — `kong-proxy` é o único Service do namespace exposto fora do cluster (NodePort).
- **Roteia** por prefixo de path: `/api/auth/*` e `/api/users/*` → `user-api`; `/api/game/*`, `/api/purchase` e `/api/eventlog/*` → `catalog-api` (tabela completa acima).
- **Valida o token JWT** via plugin nativo `jwt` do Kong, aplicado só nas rotas protegidas:
  - Algoritmo RS256, claim `iss` precisa casar com o emissor do Keycloak (`http://keycloak/realms/TechChallengeFiap`, **sem** porta — ver aviso abaixo).
  - Assinatura validada contra a chave pública real do realm, nunca contra segredo compartilhado.
  - Sem token, token expirado (`exp`) ou assinatura inválida → `401` **direto do Kong**, nunca chega em `UsersAPI`/`CatalogAPI`.

  > **`iss` sem porta:** mesmo requisitando `http://keycloak:80/...` com a porta explícita, o Keycloak emite o token com `iss: http://keycloak/realms/TechChallengeFiap` — a maioria dos clientes HTTP omite a porta padrão do header `Host`. Testado e confirmado direto no cluster. Por isso `k8s/configmaps/user-api-configmap.yaml` e `catalog-api-configmap.yaml` também usam `Keycloak__Authority` sem porta — precisa bater exatamente com o `iss` real, já que a validação é por igualdade de string.

### Por que a chave pública JWT não vem pronta no `kong-configmap.yaml`?

O Keycloak gera um par de chaves RSA novo a cada vez que o realm é importado do zero — a chave pública real não existe no momento do commit. O arquivo sobe com uma chave RSA placeholder (sintaticamente válida, mas descartável, só para o Kong conseguir inicializar) entre os marcadores `# BEGIN/END-KEYCLOAK-PUBLIC-KEY`; nenhum JWT genuíno do Keycloak valida contra ela até o script rodar. Essa chave **não é secreta** — é a mesma que qualquer cliente já lê sem autenticação em `/realms/TechChallengeFiap/protocol/openid-connect/certs` — por isso vive num ConfigMap normal, sem Secret nem indireção de vault.

### Passo a passo — subir e testar

```bash
# 1. Build das imagens do UsersAPI e CatalogAPI e carga no cluster local
cd FIAP.UsersAPI    && docker build -t fiap/usuarios-api:latest . && cd ..
cd FIAP.CatalogAPI  && docker build -t fiap/catalog-api:latest .  && cd ..
minikube image load fiap/usuarios-api:latest
minikube image load fiap/catalog-api:latest

# 2. Aplica todos os manifestos (Kong sobe com a chave placeholder)
cd FIAP.Orchestration
kubectl apply -k k8s/

# 3. Busca a chave pública real do Keycloak e reconfigura o Kong
./scripts/configure-kong-jwt.sh

# 4. Abre o túnel para o Gateway (única porta externa)
kubectl port-forward -n fiap-games svc/kong-proxy 8000:8000
```

Com o túnel aberto, em outro terminal:

```bash
# Sem token -> 401 direto do Kong, nunca chega no UsersAPI
curl -i http://localhost:8000/api/users

# Login (rota pública, form-data — não JSON)
curl -s -X POST http://localhost:8000/api/auth/login \
  -F "Username=demo.gateway" -F "Password=Demo@12345"
# -> {"access_token": "eyJ...", ...}

# Rota protegida com o token obtido acima
curl -s http://localhost:8000/api/users \
  -H "Authorization: Bearer <access_token>"

# CatalogAPI, mesmo token
curl -s http://localhost:8000/api/game \
  -H "Authorization: Bearer <access_token>"
```

> Se o cluster expõe NodePort diretamente na sua máquina (ex.: Docker Desktop/kind com port mapping — não é o caso do minikube com driver Docker), dá pra usar `http://localhost:30080` direto, sem o port-forward do passo 4.

Pra inspecionar o estado do Kong sem interface visual, a Admin API (só interna, porta 8001) devolve tudo em JSON:

```bash
kubectl port-forward -n fiap-games svc/kong-admin 8001:8001

curl -s localhost:8001/status | jq                                          # saúde, conexões, memória
curl -s localhost:8001/services | jq '.data[] | {name, host}'               # services registrados
curl -s localhost:8001/routes | jq '.data[] | {name, paths}'                # routes e paths
curl -s localhost:8001/consumers/keycloak/jwt | jq '.data[] | {key, algorithm}'  # credencial JWT
```

---

## 11. Observabilidade (Prometheus + Grafana)

**Opção escolhida: Opção A — Stack de código aberto (Prometheus + Grafana).**

- `CatalogAPI`, `UsersAPI`, `PaymentAPI` e `NotificationsAPI` expõem métricas Prometheus em `GET /metrics` (via `prometheus-net.AspNetCore`).
- O Prometheus faz scrape das 4 APIs a cada 15s (`k8s/monitoring/prometheus-configmap.yaml`); o Grafana já sobe com datasource e dashboard **FIAP APIs Overview** provisionados automaticamente (`k8s/monitoring/grafana-*`), mostrando latência (p50/p95/p99), contagem de requisições (total e por status HTTP) e taxa de erros em tempo real.
- Implantação 100% via manifestos Kubernetes, sem uso de agentes/APM comerciais (Opção B não foi utilizada).

Guia completo (queries PromQL painel a painel, como acessar local/Kubernetes, como recriar o dashboard do zero): [`monitoring/README.md`](monitoring/README.md).

---

## 12. Persistência Poliglota — MongoDB e Redis

A Fase 3 exige que a arquitetura deixe de depender exclusivamente de banco relacional. Aqui isso se traduz em duas escolhas com papéis bem distintos: **MongoDB** guarda dados que crescem sem limite e não têm formato fixo; **Redis** guarda dados quentes e descartáveis, para tirar carga do banco principal.

```
                       ┌──────────────────────────────┐
   escrita de negócio  │        SQL Server            │   verdade transacional
   ───────────────────▶│  jogos, biblioteca, usuários │
                       └──────────────────────────────┘
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        ▼                                                       ▼
┌──────────────────────┐                          ┌──────────────────────────┐
│      MongoDB         │                          │          Redis           │
│  FcgEvents.EventLogs │                          │  catalog:*  /  users:*   │
│                      │                          │                          │
│ todo evento Kafka    │                          │ consultas onerosas e     │
│ publicado/consumido  │                          │ token de sessão do       │
│ por Catalog/Payment/ │                          │ Keycloak, com TTL curto  │
│ Users                │                          │                          │
└──────────────────────┘                          └──────────────────────────┘
```

### 12.1 MongoDB — logs de eventos

**Cenário de uso:** dado de alta volumetria e formato variável. Cada tipo de evento tem um payload diferente, o volume cresce a cada compra e ninguém precisa dele numa transação — exatamente o caso em que uma tabela relacional atrapalha mais do que ajuda.

**Implementação:** driver oficial `MongoDB.Driver`. Os três serviços escrevem na **mesma base e coleção** (`FcgEvents.EventLogs`), cada um se identificando no campo `service`. É isso que permite reconstruir o fluxo inteiro de uma compra em uma consulta só, por `correlationId`.

| Serviço | O que registra |
|---|---|
| CatalogAPI | `OrderPlacedEvent` publicado, `PaymentProcessedEvent` consumido |
| PaymentAPI | `OrderPlacedEvent` consumido, `PaymentProcessedEvent` publicado |
| UsersAPI | `UserCreatedEvent` publicado |

Documento gravado (o `payload` é subdocumento real, não string — dá para filtrar por campo interno):

```json
{
  "_id": ObjectId("6a93376c823a5f7464554826"),
  "service": "CatalogAPI",
  "eventType": "OrderPlacedEvent",
  "direction": "Published",
  "topic": "order-placed",
  "correlationId": "e9d8f396-4455-4b03-a1f8-76b95a31d2c9",
  "status": "Success",
  "payload": { "UserId": "500f5643-...", "GameId": 42, "Price": 59.9 },
  "occurredAt": ISODate("2026-08-29T19:47:54.592Z")
}
```

Índices criados automaticamente na subida da CatalogAPI: `{correlationId: 1, occurredAt: -1}` e `{occurredAt: -1}`.

**Como consultar** — pelo Gateway, com o mesmo token JWT das demais rotas:

```bash
# Rastro completo de uma compra, do mais antigo ao mais recente
curl -s http://localhost:30080/api/eventlog/{correlationId} -H "Authorization: Bearer $TOKEN"

# Últimos eventos, com filtros opcionais
curl -s "http://localhost:30080/api/eventlog?service=PaymentAPI&eventType=PaymentProcessedEvent&limit=20" \
  -H "Authorization: Bearer $TOKEN"
```

Ou direto no banco:

```bash
kubectl exec -n fiap-games deploy/mongodb -- sh -c 'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin --quiet --eval \
  "db.getSiblingDB(\"FcgEvents\").EventLogs.find().sort({occurredAt:-1}).limit(10)"'
```

> **Falha ao gravar o log nunca derruba o fluxo de negócio.** O `MongoEventLogService` captura exceções e registra um erro no log da aplicação: o evento já foi publicado no Kafka e a compra segue — o log é observabilidade, não parte da transação.

**Além dos eventos**, a CatalogAPI também usa o MongoDB para *audit logs* das entidades relacionais (base `CatalogAudit`, coleção `AuditLogs`), gravados pelo interceptor de `SaveChanges` do EF Core.

### 12.2 Redis — cache distribuído

**Cenário de uso:** os dois casos citados no desafio que fazem sentido nesta arquitetura — **resultados de consultas onerosas** e **dados de sessão**.

**Implementação:** as leituras e escritas passam pela abstração `IDistributedCache` do ASP.NET Core (`AddStackExchangeRedisCache`); a invalidação por prefixo usa o `IConnectionMultiplexer` do `StackExchange.Redis` diretamente, porque varrer chaves (`SCAN`) não existe na abstração.

| Serviço | O que é cacheado | Chave | Invalidação |
|---|---|---|---|
| CatalogAPI | `GET /api/game` — listagem completa do catálogo | `catalog:games:all` | TTL 10 min + toda escrita em jogo |
| CatalogAPI | `GET /api/game/{id}` — detalhe com join de gêneros | `catalog:games:{id}` | TTL 10 min + toda escrita em jogo |
| UsersAPI | listagem de usuários (chamada HTTP à Admin API do Keycloak) | `usersapi:users:all` | TTL 60s + toda escrita em usuário |
| UsersAPI | busca por username/email | `usersapi:users:lookup:{u}:{e}` | TTL 60s + toda escrita em usuário |
| UsersAPI | **token de serviço do Keycloak** (dado de sessão) | `usersapi:session:keycloak-admin-token` | TTL = expiração do token − 30s |

O token do Keycloak é o caso mais claro de "dado de sessão": sem Redis, cada réplica da `UsersAPI` abriria seu próprio token no Keycloak a cada expiração. Com Redis, todas compartilham o mesmo, e o provider ainda mantém uma cópia local de curta duração (L1) para não ir ao Redis a cada chamada.

Escritas invalidam por prefixo (`catalog:games:` / `usersapi:users:`) — derrubar lista e detalhes de uma vez custa menos do que manter granularidade fina para um TTL desta ordem.

> **Redis fora do ar não derruba a aplicação.** Todas as operações do `RedisCacheService` capturam exceção, logam um *warning* e seguem para a origem dos dados; o multiplexer sobe com `AbortOnConnectFail = false` e reconecta em background.

### 12.3 Onde está a configuração

| Chave | Onde | Valor no cluster |
|---|---|---|
| `MongoDb__Host` / `__Port` | [`k8s/configmaps/shared-configmap.yaml`](k8s/configmaps/shared-configmap.yaml) | `mongodb` / `27017` |
| `MongoDb__EventsDatabaseName` / `__EventsCollectionName` | `shared-configmap.yaml` | `FcgEvents` / `EventLogs` |
| `MongoDb__Username` / `__Password` | Secrets `{catalog,user,payment}-api-secret` (criados por `scripts/create-k8s-secrets.sh`) | Secret |
| `MongoDb__DatabaseName` / `__CollectionName` (audit) | [`k8s/configmaps/catalog-api-configmap.yaml`](k8s/configmaps/catalog-api-configmap.yaml) | `CatalogAudit` / `AuditLogs` |
| `ConnectionStrings__Redis` | `shared-configmap.yaml` | `redis:6379` |
| `Cache__InstanceName` / `Cache__DefaultTtlSeconds` | configmap de cada serviço | `catalog:`/600s (10 min), `usersapi:`/60s |

Em Docker Compose, os mesmos valores vêm do bloco `x-datastore-env` no [`docker-compose.yml`](docker-compose.yml).

---

## 13. CI/CD e GitOps (GitHub Actions)

Todo o ciclo é automatizado com GitHub Actions e o estado de produção é declarado neste repositório: o que está em `main` do FIAP.Orchestration é o que roda no cluster.

### Fluxo

```
PR / push em qualquer API
        │
        ▼
[Build & Test] dotnet restore/build/test (.trx + cobertura como artefato)
        │
        ▼
[Containerização] docker buildx (cache GHA) → tags sha-<7>, latest, vX.Y.Z, X.Y
        │
        ▼
[Security Scan] Trivy v0.76.1 → SARIF na aba Security (repos públicos) + gate CRITICAL
        │  (PR para aqui: nada é publicado)
        ▼
[Push] ghcr.io/projeto-pos-tech-fiap/<serviço>
        │
        ▼
[Promote] commit "deploy(<serviço>): sha-xxxxxxx" em environments/production/kustomization.yaml
        │
        ▼  (push em main do Orchestration)
[Validate] kustomize build + kubeconform + guarda de rolling update + docker compose config
        │
        ▼
[Deploy] kubectl apply -k environments/production → rollout status (Rolling Update, maxUnavailable=0)
```

### Workflows

| Repositório | Arquivo | Papel |
|---|---|---|
| FIAP.Orchestration | `.github/workflows/dotnet-service.yml` | Pipeline reutilizável (`workflow_call`) das 4 APIs |
| FIAP.Orchestration | `.github/workflows/validate.yml` | Validação dos manifestos em PR e antes do deploy |
| FIAP.Orchestration | `.github/workflows/deploy-production.yml` | Aplica o overlay de produção no cluster |
| FIAP.CatalogAPI / UsersAPI / PaymentAPI / NotificationsAPI | `.github/workflows/ci-cd.yml` | Chama o pipeline reutilizável |
| FIAP.NotificationsAPI | job `deploy-lambda` em `ci-cd.yml` | Deploy opcional da Lambda (`vars.DEPLOY_LAMBDA=true`) |

### Overlay de produção

`environments/production/kustomization.yaml` usa `k8s/` como base e só troca as imagens `fiap/*:latest` pelas do GHCR com a tag imutável promovida pela pipeline, além de adicionar `imagePullSecrets: ghcr-pull-secret`. O fluxo local com minikube (`kubectl apply -k k8s/`) continua igual.

Zero downtime: os Deployments das APIs usam `RollingUpdate` com `maxSurge: 1` / `maxUnavailable: 0`, `readinessProbe` em `/health`, `minReadySeconds: 5` e `preStop` de 5s para drenar conexões. Se o novo pod não ficar pronto, o rollout falha e a versão anterior continua atendendo.

Rollback GitOps: `git revert` do commit `deploy(<serviço>): ...` neste repositório.

### Supply chain do Trivy

A `aquasecurity/trivy-action` teve tags sobrescritas por malware em março/2026 (CVE-2026-33634 / GHSA-69fq-xp46-6x23). Por isso o pipeline referencia a action pelo commit `a9c7b0f06e461e9d4b4d1711f154ee024b8d7ab8` (release `v0.36.0`, que também fixa por SHA o `setup-trivy v0.2.6` e o `actions/cache v5.0.5`) e o binário pela versão explícita `TRIVY_VERSION`. Para atualizar, confira o SHA da nova tag em https://github.com/aquasecurity/trivy-action/releases antes de trocar.

### Configuração (plano Free)

| Onde | Tipo | Nome | Valor |
|---|---|---|---|
| Cada repositório de API | Secret | `ORCHESTRATION_TOKEN` | PAT com escrita em `FIAP.Orchestration` (Contents: Read and write) |
| FIAP.Orchestration | Secret | `GHCR_PULL_TOKEN` | PAT classic com `read:packages` (só se os pacotes forem privados) |
| FIAP.Orchestration | Variable | `GHCR_PULL_USERNAME` | Usuário dono do PAT acima |
| FIAP.Orchestration | Secret | `KUBE_CONFIG` | kubeconfig em base64 (opcional; sem ele usa o kubeconfig do runner) |
| FIAP.Orchestration | Secrets | `MSSQL_SA_PASSWORD`, `MONGO_INITDB_ROOT_USERNAME`, `MONGO_INITDB_ROOT_PASSWORD`, `KEYCLOAK_POSTGRES_USER`, `KEYCLOAK_POSTGRES_PASSWORD`, `KEYCLOAK_ADMIN`, `KEYCLOAK_ADMIN_PASSWORD`, `KEYCLOAK_CLIENT_SECRET`, `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD` | Credenciais gravadas nos Secrets do cluster a cada deploy. Sem eles, o deploy exige que os Secrets já existam no cluster |
| FIAP.Orchestration | Variable | `DEPLOY_RUNS_ON` | Label do runner de deploy (padrão `self-hosted`) |
| FIAP.NotificationsAPI | Variable / Secrets | `DEPLOY_LAMBDA`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Deploy da Lambda (opcional) |

O deploy roda em um **self-hosted runner** (gratuito e sem limite de minutos) instalado na mesma máquina/WSL do minikube, porque runners hospedados pelo GitHub não alcançam um cluster local. Com um cluster acessível pela internet, basta definir `DEPLOY_RUNS_ON=ubuntu-latest` e o secret `KUBE_CONFIG`.

---

## 14. Busca Avançada — Elasticsearch

A Fase 4 exige um motor de busca **independente da consulta relacional**, com tolerância a erros de digitação e ordenação por relevância. Nenhum dos dois é possível com `LIKE '%termo%'` no SQL Server: o `LIKE` não tem noção de "quase igual" nem de "mais relevante".

```
                       ┌──────────────────────────────┐
   POST/PUT /api/game  │        SQL Server            │   verdade transacional
   ───────────────────▶│  jogos, biblioteca, usuários │
                       └──────────────┬───────────────┘
                                      │ indexação síncrona
                                      │ (GameService, após o commit)
                                      ▼
                       ┌──────────────────────────────┐
   GET /api/search     │      Elasticsearch           │   índice `games`
   ◀───────────────────│  fuzzy + score de relevância │
                       └──────────────────────────────┘
```

**Serviço:** Elasticsearch 8.19 — `docker.elastic.co/elasticsearch/elasticsearch:8.19.5`, nó único, no Compose e no cluster. A `Uri` e as credenciais vêm de configuração, então trocar para **Elastic Cloud** ou **Amazon OpenSearch** não exige recompilar nada.

**Implementação:** cliente oficial `Elastic.Clients.Elasticsearch` 8.19, registrado como singleton (é thread-safe e mantém o próprio pool de conexões). Só a **CatalogAPI** usa.

**Sincronização:** no `GameService`, logo depois da escrita no SQL Server — `POST`/`PUT` reindexam o jogo, `DELETE` o remove do índice. As escritas usam `refresh=true`, então o jogo recém-criado já aparece na busca seguinte. Falha ao indexar **não** derruba a escrita: a gravação no banco principal já aconteceu, o erro vai para o log nomeando o jogo que ficou de fora, e o índice é reconciliado por `POST /api/search/reindex` — que reverifica o índice, grava tudo em um `_bulk` e apaga os órfãos por `_delete_by_query`, deixando o índice igual ao banco.

**Funcionalidades do `/search`:** `multi_match` com `fuzziness: AUTO` sobre título (peso 4), gêneros e desenvolvedora (2), publicadora (1.5) e descrição; `match_phrase` no título com `boost: 6` para que o acerto exato fique acima do aproximado; filtros de gênero, faixa de preço e `isActive` em cláusula `filter`, que recorta sem pontuar. A ordenação é por `_score` quando há termo e alfabética quando não há.

```bash
# "wticher" (letras trocadas) encontra "The Witcher 3"
curl "http://localhost:5001/api/search?q=wticher"

# Filtros combinados
curl "http://localhost:5001/api/search?q=rpg&genre=RPG&minPrice=50&maxPrice=200"

# Carga inicial / reconciliação do índice
curl -X POST http://localhost:5001/api/search/reindex -H "Authorization: Bearer $TOKEN"
```

> **Cluster fora do ar devolve `503`, não um resultado pior.** Diferente do cache, a busca não tem equivalente no banco relacional — degradar em silêncio aqui significaria devolver uma busca sem fuzzy e sem relevância, o que é pior do que falhar. O índice é criado no start por um `BackgroundService` com retry, porque a API quase sempre sobe antes do Elasticsearch ficar pronto.

### 14.1 Onde está a configuração

| Chave | Onde | Valor no cluster |
|---|---|---|
| `Elasticsearch__Uri` | [`k8s/configmaps/catalog-api-configmap.yaml`](k8s/configmaps/catalog-api-configmap.yaml) | `http://elasticsearch:9200` |
| `Elasticsearch__GamesIndex` | `catalog-api-configmap.yaml` | `games` |
| `Elasticsearch__Fuzziness` | `catalog-api-configmap.yaml` | `AUTO` |
| `Elasticsearch__RequestTimeoutSeconds` | `catalog-api-configmap.yaml` | `10` |
| `Elasticsearch__ApiKey` | `ELASTICSEARCH_API_KEY` no `.env` → [`scripts/create-k8s-secrets.sh`](scripts/create-k8s-secrets.sh) | Secret criada fora do git |

Fica no configmap da CatalogAPI e não no `shared-infra-config` porque nenhum outro serviço usa o Elasticsearch. Em Docker Compose os mesmos valores estão no bloco do serviço `catalog-api` no [`docker-compose.yml`](docker-compose.yml).

A `ApiKey` é **opcional e não entra na lista `REQUIRED`** do script: o cluster local sobe com `xpack.security.enabled=false`, então não há credencial a injetar. Ela só é necessária ao apontar a `Uri` para um endpoint gerenciado, e aí entra pela Secret — nenhuma credencial versionada, como o resto da plataforma depois da seção de gestão de segredos.

### 14.2 Manifestos

| Arquivo | Conteúdo |
|---|---|
| [`k8s/infrastructure/elasticsearch-deployment.yaml`](k8s/infrastructure/elasticsearch-deployment.yaml) | `discovery.type=single-node`, heap de 512 MB, `strategy: Recreate` (PVC `ReadWriteOnce` não aceita dois pods), *initContainer* que ajusta o dono do diretório de dados para o uid 1000 |
| [`k8s/infrastructure/elasticsearch-service.yaml`](k8s/infrastructure/elasticsearch-service.yaml) | `ClusterIP` na porta 9200 — sem exposição externa, igual ao Redis e ao Mongo |
| [`k8s/infrastructure/elasticsearch-pvc.yaml`](k8s/infrastructure/elasticsearch-pvc.yaml) | 2Gi para o índice |

Detalhes do mapping, do analisador e do comportamento sob falha em [`FIAP.CatalogAPI/README.md` § 11](../FIAP.CatalogAPI/README.md#11-busca-avançada--elasticsearch).

---

## 15. Infraestrutura Gerenciada no Azure — AKS e ACR

O ambiente de produção é um **Kubernetes gerenciado** (AKS) com **registry privado nativo da cloud** (ACR). O cluster local com minikube continua valendo para desenvolvimento — a diferença entre os dois está no overlay, não no código nem na imagem.

### O que o provisionamento cria

| Recurso | Para que serve |
|---|---|
| Resource group `rg-fcg-prod` | Agrupa tudo; apagar o grupo apaga a conta do mês |
| **ACR** (sku Basic, `--admin-enabled false`) | Registry privado. Sem usuário e senha de registry: o acesso é por identidade |
| **AKS** (tier Free, 2 × `Standard_B2s`, Entra ID + RBAC do Azure) | Cluster gerenciado. `--attach-acr` dá `AcrPull` à identidade do kubelet, então **nenhum `imagePullSecret` existe no cluster** |
| **Managed identity** + federated credentials | Identidade que o GitHub Actions assume por OIDC |
| Load Balancer público | Criado pelo Azure quando o `kong-proxy` sobe como `LoadBalancer` no overlay de produção |

```bash
az login
ACR_NAME=acrfcg$RANDOM bash scripts/azure-provision.sh
```

O script é idempotente e imprime no fim as *Variables* a configurar no GitHub. Para desligar e parar o custo: `az group delete --name rg-fcg-prod --yes`.

> **Custo:** o control plane do AKS no tier Free não é cobrado, mas nós, discos, Load Balancer e tráfego são. A ordem de grandeza da configuração padrão é de algumas dezenas de dólares por mês.

### Autenticação sem segredo — OIDC

Nem a pipeline nem o deploy guardam credencial de nuvem. O runner troca o próprio token do GitHub por um token do Azure, e o Azure só aceita a troca se o `subject` do token casar com um federated credential registrado:

```
repo:Projeto-Pos-Tech-FIAP/FIAP.CatalogAPI:ref:refs/heads/main   → publicar imagem no ACR
repo:Projeto-Pos-Tech-FIAP/FIAP.Orchestration:environment:production → aplicar manifesto no AKS
```

A identidade recebe exatamente três papéis: `AcrPush` no registry, *Cluster User* no AKS e **RBAC Writer apenas no namespace `fiap-games`** — a pipeline não consegue alterar RBAC nem tocar em outros namespaces.

### Variables (nenhum Secret)

| Variable | Exemplo | Efeito |
|---|---|---|
| `ACR_LOGIN_SERVER` | `acrfcg123.azurecr.io` | Definida: a pipeline publica no ACR. Vazia: publica no GHCR |
| `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` | — | Identidade assumida por OIDC |
| `AKS_RESOURCE_GROUP` / `AKS_CLUSTER_NAME` | `rg-fcg-prod` / `aks-fcg-prod` | Definidas: o deploy pega o kubeconfig com `az aks get-credentials`. Vazias: usa o Secret `KUBE_CONFIG` |

Definidas no nível da organização, valem para os cinco repositórios de uma vez. A troca de GHCR para ACR é só a Variable: a pipeline grava no overlay o registry em que publicou, e o commit de deploy registra a mudança.

### Exposição externa

`environments/production/kustomization.yaml` troca o `kong-proxy` de `NodePort` para `LoadBalancer`. O Azure provisiona o Load Balancer e devolve o IP público:

```bash
kubectl get svc kong-proxy -n fiap-games -w
curl -s http://<EXTERNAL-IP>:8000/api/game
```

As APIs seguem `ClusterIP` — Kong continua sendo o único ponto de entrada.

### Elasticsearch gerenciado

O cluster in-cluster (`k8s/infrastructure/elasticsearch-*.yaml`) atende o requisito funcional, mas para endpoint gerenciado (Elastic Cloud na Azure ou Amazon OpenSearch) **não há mudança de código**: basta apontar `Elasticsearch__Uri` no ConfigMap do catálogo e pôr `ELASTICSEARCH_API_KEY` no `.env` antes de rodar `scripts/create-k8s-secrets.sh`.

---

## 16. Próximos Passos

### Como adicionar UserAPI / PaymentAPI / NotificationAPI

Cada novo microserviço segue o mesmo padrão do CatalogAPI:

| Passo | Ação |
|---|---|
| 1 | Criar repositório `FIAP.UserAPI` com a mesma Clean Architecture |
| 2 | Adicionar `Dockerfile` multi-stage e `.dockerignore` |
| 3 | Criar `k8s/` com configmap, deployment e service; o Secret entra em `scripts/create-k8s-secrets.sh` |
| 4 | No `docker-compose.yml`: descomentar o bloco do serviço |
| 5 | Fazer o `docker build` e `kubectl apply` |

Os manifestos em `k8s/services/user-api-*.yaml` já estão prontos — basta ter a imagem `fiap/user-api:latest` disponível.

### Roadmap de Comunicação Kafka

| Serviço | Publica | Consome |
|---|---|---|
| CatalogAPI | `order-placed` | `payment-processed` |
| UserAPI | `user-created` | — |
| PaymentAPI | `payment-processed`, `notification-requested` | `order-placed` |
| NotificationAPI | — | `notification-requested` |

### Melhorias Sugeridas para Produção

- Habilitar **TLS** no `kong-proxy` (hoje HTTP puro) e trocar `NodePort` por `LoadBalancer`/Ingress na frente do Kong
- Rodar o Kong com banco (Postgres) + réplicas se a config declarativa DB-less deixar de ser suficiente para o time
- Substituir Deployments de banco por **StatefulSets** para melhor gerenciamento de estado
- Usar **Sealed Secrets** ou **External Secrets Operator** para secrets seguros em Git
- Adicionar **HorizontalPodAutoscaler** para escala automática baseada em CPU/memória
- Configurar **PodDisruptionBudget** para manter disponibilidade durante atualizações
- Adicionar **NetworkPolicy** para isolar comunicação entre namespaces
- Subir Kafka para **3 brokers** com fator de replicação 3 para alta disponibilidade
