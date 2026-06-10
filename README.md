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
10. [Próximos Passos](#10-próximos-passos)

---

## 1. Visão Geral da Plataforma

A plataforma FIAP Games é composta por quatro microserviços que se comunicam via **Apache Kafka**, com infraestrutura de suporte centralizada (SQL Server, MongoDB e Redis).

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
| MongoDB.Driver | 3.x | Audit logs em MongoDB |
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
│   │   ├── secret.yaml
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── Dockerfile                 ← Multi-stage build
│   └── .dockerignore
│
└── FIAP.Orchestration/            ← Este repositório (infraestrutura)
    ├── docker-compose.yml         ← Stack completa local
    └── k8s/
        ├── 00-namespace.yaml
        ├── kustomization.yaml     ← Aplica tudo com 1 comando
        ├── configmaps/            ← Dados não-sensíveis
        ├── secrets/               ← Dados sensíveis
        ├── infrastructure/        ← SQL, Mongo, Redis, Kafka
        └── services/              ← Todos os microserviços
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
| SQL Server | localhost:1433 | `sa` / `PosTech@123` |
| MongoDB | localhost:27018 | `admin` / `PosTech@123` |
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

# Passo 3: Aplicar todos os manifestos com Kustomize
cd FIAP.Orchestration
kubectl apply -k k8s/

# Passo 4: Aguardar pods iniciarem
kubectl get pods -n fiap-games -w

# Passo 5: Port-forward para acessar a API
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

> **Secrets em produção:** os arquivos `secrets/*.yaml` contêm credenciais em texto plano. Para ambientes reais, use **Sealed Secrets**, **External Secrets Operator** ou **HashiCorp Vault** — nunca commite credenciais reais no Git.

---

## 10. Próximos Passos

### Como adicionar UserAPI / PaymentAPI / NotificationAPI

Cada novo microserviço segue o mesmo padrão do CatalogAPI:

| Passo | Ação |
|---|---|
| 1 | Criar repositório `FIAP.UserAPI` com a mesma Clean Architecture |
| 2 | Adicionar `Dockerfile` multi-stage e `.dockerignore` |
| 3 | Criar `k8s/` com configmap, secret, deployment e service |
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

- Adicionar **Ingress** (Nginx/Traefik) para expor APIs externamente com TLS
- Substituir Deployments de banco por **StatefulSets** para melhor gerenciamento de estado
- Usar **Sealed Secrets** ou **External Secrets Operator** para secrets seguros em Git
- Adicionar **HorizontalPodAutoscaler** para escala automática baseada em CPU/memória
- Configurar **PodDisruptionBudget** para manter disponibilidade durante atualizações
- Adicionar **NetworkPolicy** para isolar comunicação entre namespaces
- Subir Kafka para **3 brokers** com fator de replicação 3 para alta disponibilidade
