# Roteiro do Pitch Final — Fase 4 (até 25 min)

Os quatro itens que o enunciado exige da apresentação são, em ordem: **infra na nuvem**, **live deploy**, **busca e cache**, **NoSQL na arquitetura**. Todo o resto é moldura. O roteiro abaixo cobre os quatro com folga e deixa 1 min de reserva.

## Antes de gravar

| Passo | Por quê |
|---|---|
| Rode o fluxo inteiro uma vez, sem gravar | O `deploy-production` leva ~4 min; você precisa saber o tempo real antes de narrar |
| `kubectl get pods -n fiap-games` com tudo `Running` | SQL Server e Keycloak demoram no primeiro start; não grave em cima disso |
| Faça um login e uma compra | Popula o índice e o log de eventos: a demo fica com dados de verdade |
| `POST /api/search/reindex` | Garante que o catálogo inteiro está no índice |
| Fonte do terminal grande (16pt+) e tema claro | Metade dos vídeos reprovados é por terminal ilegível |
| Deixe o commit do live deploy pronto num branch local | Você só dá `git commit --amend` e `push` na hora |
| Grave uma vez e assista | O primeiro take sempre tem 3 min de gordura |

Divida a fala entre os três: quem fez cada parte apresenta a sua. Avaliador percebe quando uma pessoa narra o trabalho das outras.

## Minutagem

### 1. Abertura — 0:00 a 1:30
Diga o problema da fase em uma frase: *a plataforma funcionava, mas dependia de cluster local, deploy manual e busca com `LIKE`*. Mostre o diagrama da arquitetura e aponte os três gargalos e o que resolveu cada um. Não leia o diagrama inteiro.

### 2. Infraestrutura gerenciada — 1:30 a 4:30
Portal do Azure, resource group `rg-fcg-prod`:

- **AKS `aks-fcg-prod`** — diga "Kubernetes gerenciado, tier Free, 2 nós, Entra ID com Azure RBAC". Mostre `kubectl get nodes` e `kubectl get pods -n fiap-games`.
- **ACR `acrfcgprod2046`** — mostre as 4 imagens com as tags `sha-<commit>`. Frase que vale ponto: *"o registry é privado, com usuário admin desabilitado; quem puxa imagem é a identidade do kubelet, então não existe `imagePullSecret` nenhum no cluster"*.
- **Exposição** — `kubectl get svc kong-proxy -n fiap-games` mostrando o `EXTERNAL-IP` do Load Balancer, e um `curl` nesse IP. Diga que as APIs são `ClusterIP` e que Kong é o único ponto de entrada.

### 3. Live deploy — 4:30 a 9:30
O item mais valioso da nota. Deixe um `curl` em loop rodando numa aba para provar que não cai:

```bash
while true; do curl -s -o /dev/null -w "%{http_code} " http://<EXTERNAL-IP>:8000/api/game; sleep 1; done
```

Altere algo **visível na resposta** (um campo, uma mensagem), `git push` na `main` e narre a pipeline enquanto roda: build e testes → imagem com tag do commit → Trivy → push no ACR por OIDC → *promote* commitando a tag no overlay → `deploy-production` aplicando no AKS. Em outra aba, `kubectl get pods -n fiap-games -w`.

Duas frases que mostram domínio:

- *"não existe senha de nuvem no GitHub: o runner troca o token dele por um do Azure, e o Azure só aceita se o repositório e a branch casarem com o federated credential"*;
- *"o estado de produção é o que está commitado no overlay — a pipeline escreve a tag lá, então todo deploy tem um commit que o explica"*.

Feche mostrando a aba do `curl`: só `200`, nenhum erro. É a prova do `maxUnavailable: 0`.

### 4. Busca avançada — 9:30 a 14:00
```bash
curl -s "http://<IP>:8000/api/search?q=couter%20strke" | jq '.hits[] | {title, score}'
```

Mostre que o erro de digitação acha o jogo e que a ordem segue o `score`, não o id nem o alfabeto. Então:

1. Crie ou edite um jogo pelo `POST /api/game` e repita a busca — o índice já reflete, porque o `GameService` reindexa depois da escrita.
2. Se sobrar tempo, derrube o pod do Elasticsearch e mostre o `503` com mensagem explícita. Diga por que **não** degradar para o SQL: *"fuzzy e relevância não existem no banco relacional; devolver uma busca pior em silêncio seria enganar o cliente"*.

### 5. Cache — 14:00 a 18:00
```bash
time curl -s "http://<IP>:8000/api/game/1" -H "Authorization: Bearer $TOKEN" > /dev/null   # vai ao banco
time curl -s "http://<IP>:8000/api/game/1" -H "Authorization: Bearer $TOKEN" > /dev/null   # vem do Redis
```

Mostre os dois tempos na tela. Depois edite o jogo e repita: a resposta vem atualizada, porque a escrita invalida o cache por prefixo. Mencione o segundo uso, que é o mais interessante: o token de serviço do Keycloak fica no Redis compartilhado entre as réplicas da UsersAPI, com TTL casado na expiração do token.

### 6. NoSQL — 18:00 a 22:00
Explique a decisão antes de mostrar a tela: *log de eventos do fluxo de compra é dado de alta volumetria, schema variável por tipo de evento e só cresce — é exatamente o que o relacional faz mal e o documento faz bem*. Então:

```bash
curl -s "http://<IP>:8000/api/eventlog/$CORRELATION_ID" -H "Authorization: Bearer $TOKEN" | jq
```

Mostre os quatro eventos do fluxo — publicado e consumido de cada lado — correlacionados pelo mesmo `correlationId` atravessando Catalog, Payment e Notifications via Kafka.

### 7. Segurança e segredos — 22:00 a 24:00
```bash
git grep -nE "Password|ClientSecret" -- '*.json' '*.yaml' | grep -v CHANGE_ME
```

Sai vazio: é a prova do "zero hardcoded credentials". Complete mostrando que **o GitHub não tem nenhum Secret de nuvem** — só Variables com identificadores — e que a identidade da pipeline é *RBAC Writer apenas no namespace* `fiap-games`.

### 8. Encerramento — 24:00 a 25:00
Diga o que ficou de fora e por quê, em uma frase: *o Elasticsearch roda como Deployment no AKS e não como serviço gerenciado; o Marketplace da Azure está bloqueado na subscription de estudante, e a troca é só de configuração — `Uri` e chave — sem mudança de código*. Admitir isso custa muito menos que ser pego.

## Se o PAT do `ORCHESTRATION_TOKEN` não estiver pronto

O *promote* falha e o live deploy não acontece sozinho. Plano B, assumido na narração: rode o `deploy-production` por `workflow_dispatch` depois de atualizar a tag no overlay à mão, e diga que a automação do commit depende de um token de escrita entre repositórios. Fica honesto, mas vale menos — tente ter o PAT.
