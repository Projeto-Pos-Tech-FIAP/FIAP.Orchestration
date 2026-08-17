# Observabilidade — Prometheus + Grafana

Métricas em tempo real das 4 APIs da plataforma FIAP Games (CatalogAPI, UsersAPI, PaymentAPI, NotificationsAPI): **latência de requisições**, **contagem de requisições (total e por status HTTP)** e **taxa de erros**.

## Como funciona

- Cada API expõe métricas no formato Prometheus em `GET /metrics` (biblioteca `prometheus-net.AspNetCore`, via `UseHttpMetrics()` + `MapMetrics()` no `Program.cs`).
- O **Prometheus** raspa esse endpoint das 4 APIs a cada 15s e guarda as séries temporais.
- O **Grafana** lê do Prometheus e desenha os painéis. Datasource e dashboard já vêm provisionados automaticamente.

Métricas principais expostas pelo `prometheus-net`:

| Métrica | Tipo | Uso |
|---|---|---|
| `http_requests_received_total` | counter | contagem de requisições, com labels `method`, `code`, `controller`, `action` |
| `http_request_duration_seconds` | histogram | latência (via buckets `_bucket`, `_sum`, `_count`) |

## Subindo com Docker Compose

Na raiz do `FIAP.Orchestration`:

```bash
docker compose up -d --build
```

Acessos:

| Serviço | URL | Login |
|---|---|---|
| Grafana | http://localhost:3000 | admin / admin123 |
| Prometheus | http://localhost:9090 | — |
| Catalog `/metrics` | http://localhost:5001/metrics | — |
| Users `/metrics` | http://localhost:5002/metrics | — |
| Payment `/metrics` | http://localhost:5003/metrics | — |
| Notifications `/metrics` | http://localhost:5004/metrics | — |

O dashboard **FIAP APIs Overview** aparece em *Dashboards → FIAP Games* já com dados assim que houver tráfego nas APIs.

## Subindo no Kubernetes (Minikube)

Os manifestos estão em `k8s/monitoring/` e já entram no `kustomization.yaml`.

```bash
kubectl apply -k k8s/
kubectl get pods -n fiap-games   # prometheus e grafana devem ficar Running
```

Como os Services são `ClusterIP`, acesse via port-forward:

```bash
kubectl port-forward -n fiap-games svc/grafana 3000:3000
kubectl port-forward -n fiap-games svc/prometheus 9090:9090
```

## Verificação rápida

1. Gere tráfego nas APIs (ex.: login no Users, listar jogos no Catalog, fazer uma compra).
2. Abra http://localhost:9090/targets e confirme que os 4 jobs estão **UP**.
3. Abra o Grafana e veja os painéis preenchendo. Use o filtro **API (job)** no topo para isolar um serviço.

---

## Passo a passo: montar o dashboard manualmente no Grafana

O dashboard já vem pronto (provisionado). Este guia é para reproduzir/entender os painéis à mão.

### 1. Preparar

1. Suba a stack (`docker compose up -d`) e gere algumas requisições nas APIs.
2. Confirme em http://localhost:9090/targets que os jobs estão **UP**.
3. Abra http://localhost:3000 e faça login (`admin` / `admin123`).

### 2. Datasource (se ainda não existir)

*Connections → Data sources → Add data source → Prometheus* → URL `http://prometheus:9090` → **Save & test**.

### 3. Criar o dashboard

*Dashboards → New → New dashboard → Add visualization* → selecione o datasource Prometheus.

### 4. Painel 1 — Requisições/s (throughput)

- Tipo: **Stat** (ou Time series).
- Query (modo Code):
  ```promql
  sum(rate(http_requests_received_total[1m]))
  ```
- Título: `Requisições/s`. Clique em **Apply**.

### 5. Painel 2 — Requisições por status HTTP

- *Add → Visualization*, tipo **Time series**.
- Query:
  ```promql
  sum by (code) (rate(http_requests_received_total[1m]))
  ```
- Legend: `{{code}}`. Título: `Requisições por status`.

### 6. Painel 3 — Latência (p50 / p95 / p99)

- Tipo **Time series**. Três queries (A, B, C), trocando o quantil:
  ```promql
  histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
  histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
  histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
  ```
- Em *Standard options → Unit* escolha **seconds (s)**. Legends: `p50`, `p95`, `p99`.

### 7. Painel 4 — Taxa de erro

- Tipo **Stat**.
- Query (proporção de respostas 5xx):
  ```promql
  sum(rate(http_requests_received_total{code=~"5.."}[5m]))
    / sum(rate(http_requests_received_total[5m]))
  ```
- Unidade: *Percent (0.0–1.0)*. Em *Thresholds*, defina verde / amarelo (0.01) / vermelho (0.05).

### 8. Filtrar por API (variável de template)

- *Dashboard settings → Variables → New variable*.
- Type: **Query**, Name: `job`, Data source: Prometheus.
- Query: `label_values(http_requests_received_total, job)`. Marque **Include All** e **Multi-value**.
- Volte aos painéis e troque cada métrica de `http_requests_received_total` para `http_requests_received_total{job=~"$job"}` (idem no `_bucket` da latência). O dropdown aparece no topo do dashboard.

### 9. Salvar / versionar

- Salve com o ícone de disquete.
- Para versionar no git: *Export → Save to file* (ou copie o JSON) e coloque em `monitoring/grafana/dashboards/`.
