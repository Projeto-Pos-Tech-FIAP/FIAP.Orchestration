# Como rodar o projeto

## Opção 1 — Docker Compose (mais rápido, pra testar local)

```bash
cd FIAP.Orchestration
docker compose up -d --build
docker compose ps          # confirma tudo Up/healthy
```

> **Se o Kafka sair com `Exited (1)` e o log disser `keystore password was incorrect`:** seu `.env` define `KAFKA_TUNNEL_KEYSTORE_PASSWORD` (a senha dos certificados reais) mas não define `KAFKA_CERTS_DIR` — aí o compose monta o keystore *placeholder* de `kafka-certs-default/` com a senha real. Ou acrescente `KAFKA_CERTS_DIR=../FIAP.NotificationsAPI/kafka-certs` ao `.env`, ou remova a linha da senha para voltar ao par placeholder/senha padrão.
>
> A porta **1433** também precisa estar livre — um SQL Server de outro projeto rodando nela impede o `fiap-sqlserver` de subir.

Acessos:
| Serviço | URL |
|---|---|
| CatalogAPI | http://localhost:5001/swagger |
| UsersAPI | http://localhost:5002/swagger |
| PaymentAPI | http://localhost:5003/swagger |
| NotificationsAPI | http://localhost:5004/swagger |
| Keycloak | http://localhost:8081 |
| Kafka UI | http://localhost:8090 |

Parar:
```bash
docker compose down        # mantém os dados
docker compose down -v     # apaga tudo (reset completo)
```

## Opção 2 — Kubernetes (Minikube)

Pré-requisito: Minikube instalado e rodando dentro do WSL (`wsl.exe -d debian -e bash -lc "minikube status"`).

Tudo a partir da pasta `FIAP.Orchestration` — o script `k8s-build-images.sh` já sabe onde ficam os outros 3 repositórios (`../FIAP.CatalogAPI`, etc.):

```bash
# 1. Buildar as 4 imagens direto no Docker do Minikube
wsl.exe -d debian -e bash -lc "cd /home/brunomateus/projects/personal/fiap/FIAP.Orchestration && ./k8s-build-images.sh"

# 2. Aplicar todos os manifestos
wsl.exe -d debian -e bash -lc "cd /home/brunomateus/projects/personal/fiap/FIAP.Orchestration && kubectl apply -k k8s/"

# 3. Acompanhar até todos ficarem 1/1 Ready (leva alguns minutos na primeira vez, baixando imagens)
wsl.exe -d debian -e bash -lc "kubectl get pods -n fiap-games -w"
```

Acessar os serviços (Services são `ClusterIP`, só internos ao cluster — precisa de `port-forward`):
```bash
wsl.exe -d debian -e bash -lc "
  nohup kubectl port-forward svc/catalog-api 5001:80 -n fiap-games > /tmp/pf-catalog.log 2>&1 &
  nohup kubectl port-forward svc/user-api 5002:80 -n fiap-games > /tmp/pf-user.log 2>&1 &
  nohup kubectl port-forward svc/payment-api 5003:80 -n fiap-games > /tmp/pf-payment.log 2>&1 &
  nohup kubectl port-forward svc/notification-api 5004:80 -n fiap-games > /tmp/pf-notification.log 2>&1 &
  nohup kubectl port-forward svc/keycloak 8081:80 -n fiap-games > /tmp/pf-keycloak.log 2>&1 &
  disown -a
"
```
Mesmas URLs da tabela acima (exceto Kafka UI, que não está no k8s). CatalogAPI roda em modo `Production` no k8s — sem Swagger, só os endpoints via curl/Postman.

Parar/resetar:
```bash
wsl.exe -d debian -e bash -lc "pkill -f 'kubectl port-forward'"   # só os port-forward
wsl.exe -d debian -e bash -lc "minikube stop"                      # pausa o cluster, mantém dados
wsl.exe -d debian -e bash -lc "minikube delete"                    # apaga tudo (reset completo)
```

## Depois de subir (qualquer uma das opções) — preparar dados de teste

O banco começa vazio. Antes de testar o fluxo de compra:

1. **Criar usuário no Keycloak**: `http://localhost:8081` → login `admin`/`admin123` → trocar realm pra `TechChallengeFiap` → **Users** → **Add user** → aba **Credentials** → **Set password** (desmarcar **Temporary**)
2. **Cadastrar um jogo**: `POST /api/Game` no CatalogAPI (sem autenticação)
3. **Logar**: `POST /api/Auth/login` no UsersAPI com o usuário criado → pegar o `access_token`
4. **Comprar**: `POST /api/Purchase` no CatalogAPI com `Authorization: Bearer <token>` e `{"gameId": <id do passo 2>}`

Isso dispara o fluxo completo: CatalogAPI publica `order-placed` → PaymentAPI processa e publica `payment-processed` → CatalogAPI credita a biblioteca e NotificationsAPI "envia" o e-mail de confirmação.

5. **Ver o rastro no MongoDB**: a resposta do passo 4 traz um `correlationId`. Com ele:
   `GET /api/EventLog/{correlationId}` no CatalogAPI (com o mesmo `Bearer <token>`) devolve os 4 eventos do fluxo — publicado e consumido de cada lado — lidos da coleção `FcgEvents.EventLogs`.

6. **Ver o cache Redis funcionando**: chamar `GET /api/Game` duas vezes seguidas e olhar o log da CatalogAPI (`Cache MISS` na primeira, `Cache HIT` na segunda). Um `PUT`/`POST` em `/api/Game` invalida o prefixo e a próxima leitura volta a ser MISS.
   ```bash
   docker exec fiap-redis redis-cli KEYS 'catalog:*'    # Docker Compose
   kubectl exec -n fiap-games deploy/redis -- redis-cli KEYS 'catalog:*'
   ```
