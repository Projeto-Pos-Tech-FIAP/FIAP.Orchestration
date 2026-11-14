# Narração do Pitch Final — texto para ler

Fala palavra por palavra, só com CLI (fora 40s de portal no item 2). Marcações:
**[CMD]** é comando para rodar, *(ação)* é o que fazer na tela. Os nomes indicam
quem fala — troque como preferirem, mas mantenham cada parte com quem a fez.

Pressupõe a aplicação já no ar no AKS. Tempo total: ~24 min.

---

## 1. Abertura — Bruno — 1:30

> Boa tarde. Somos Bruno, Matheus e Lucas, e esta é a entrega da Fase 4 do Tech Challenge: a FIAP Cloud Games.
>
> Nas fases anteriores a plataforma já funcionava: quatro microsserviços em .NET, comunicação por Kafka, autenticação no Keycloak, tudo rodando em Kubernetes. O problema é que esse Kubernetes era local, o deploy era manual, e a busca do catálogo era um `LIKE` no SQL Server.
>
> Esta fase atacou exatamente esses três pontos. Primeiro: o cluster saiu da máquina de desenvolvimento e virou um Kubernetes gerenciado na Azure, o AKS, com registry privado na nuvem. Segundo: o deploy deixou de ser manual — hoje um push na main publica imagem, atualiza produção e faz rolling update sem downtime. Terceiro: a persistência deixou de ser só relacional. Entrou MongoDB para os dados de alta volumetria, Redis como cache distribuído, e Elasticsearch como motor de busca, com tolerância a erro de digitação e ordenação por relevância.
>
> Vamos mostrar cada um desses pontos rodando. Começando pela infraestrutura.

---

## 2. Infraestrutura gerenciada — Bruno — 3:00

*(abrir o portal da Azure no resource group `rg-fcg-prod` — 40 segundos, só para mostrar os recursos existindo)*

> Esta é a subscription na Azure. No resource group `rg-fcg-prod` tem três recursos: o cluster AKS, o Container Registry e uma managed identity, que eu explico já. Daqui para frente eu sigo pelo terminal, que é mais legível.

**[CMD]** `az aks list -o table`

> O cluster é `aks-fcg-prod`, na região Brazil South, Kubernetes 1.36, estado Succeeded. É um cluster gerenciado — o control plane é da Azure, nós não administramos máquina nenhuma. O enunciado era explícito em não aceitar container rodando em VM solta, e aqui não tem VM solta: tem um AKS.

**[CMD]** `kubectl get nodes`

> Dois nós, os dois Ready. São `Standard_D2as_v4`, dois vCPU cada. Esse tamanho não foi escolha estética: a subscription é Azure for Students, e ela proíbe a série B e dá quota zero para as famílias v5 e v6. Sobrou a v4, com limite de quatro vCPU — que é exatamente dois nós desse tamanho.

**[CMD]** `kubectl get pods -n fiap-games`

> Esses são os pods da plataforma: as quatro APIs, o SQL Server, o MongoDB, o Redis, o Elasticsearch, o Kafka com o ZooKeeper, o Keycloak com o Postgres dele, o Kong e o par Prometheus e Grafana.

**[CMD]** `az acr repository list --name acrfcgprod2046 -o table`

**[CMD]** `az acr repository show-tags --name acrfcgprod2046 --repository catalog-api -o table`

> O registry é o Azure Container Registry, privado, nativo da cloud — não é Docker Hub e não é mais o GHCR. Cada serviço tem a tag `latest` e uma tag com o hash do commit que gerou a imagem.
>
> E tem um detalhe que vale dizer: esse registry está com o usuário administrador **desabilitado**. Não existe senha de registry em lugar nenhum. Quem puxa imagem é a identidade do próprio kubelet do AKS, que recebeu permissão de leitura no ACR quando o cluster foi criado. Por isso não existe um único `imagePullSecret` dentro do cluster.

**[CMD]** `kubectl get svc kong-proxy -n fiap-games`

> E esta é a exposição externa: o Kong está como `LoadBalancer`, e a Azure provisionou um IP público para ele. Esse é o único ponto de entrada do sistema — as quatro APIs são `ClusterIP`, ninguém chega nelas direto de fora. O Kong valida o JWT antes de encaminhar.

---

## 3. Live deploy — Matheus — 5:00

> Agora o deploy automático. Vou alterar o código, dar push, e a aplicação em produção vai se atualizar sozinha. Antes de começar, deixo isto rodando:

**[CMD]** `while true; do curl -s -o /dev/null -w "%{http_code} " http://<IP>:8000/api/game; sleep 1; done`

> É um curl por segundo no endpoint de catálogo, através do gateway. Ele vai ficar aí o deploy inteiro, e no fim a gente olha se apareceu algum erro.

*(em outra aba, alterar algo visível na resposta da API; commit e push na main)*

**[CMD]** `git commit -am "ajuste visivel na resposta do catalogo" && git push`

**[CMD]** `gh run watch --repo Projeto-Pos-Tech-FIAP/FIAP.CatalogAPI`

> A pipeline tem três etapas. A primeira compila e roda os testes unitários. A segunda constrói a imagem Docker, passa o Trivy para procurar vulnerabilidade e, se não houver nada crítico, publica no ACR com a tag do commit.
>
> E aqui tem a parte que eu queria destacar: **não existe nenhuma senha da Azure guardada no GitHub**. O runner troca o token dele próprio por um token da Azure, usando OIDC. A Azure só aceita essa troca se o repositório e a branch de origem casarem exatamente com um federated credential que a gente registrou. Dá para ver:

**[CMD]** `az identity federated-credential list --identity-name id-fcg-github-actions -g rg-fcg-prod --query "[].{nome:name, subject:subject}" -o table`

> São cinco: um por repositório de API, mais um para o ambiente de produção do repositório de orquestração. Se alguém clonar nosso workflow em outro repositório, a Azure recusa o token.

**[CMD]** `gh variable list --repo Projeto-Pos-Tech-FIAP/FIAP.CatalogAPI`

> E é só isso que o GitHub guarda: seis variáveis, todas identificadores públicos. Nenhum segredo de nuvem.
>
> A terceira etapa é o GitOps. A pipeline não aplica nada no cluster diretamente: ela faz um commit no repositório de orquestração, trocando a tag da imagem no overlay de produção. Esse commit é que dispara o deploy. Ou seja, o que está em produção é sempre o que está commitado — todo deploy tem um commit que o explica.

*(trocar para a aba do deploy no repositório de orquestração)*

**[CMD]** `gh run watch --repo Projeto-Pos-Tech-FIAP/FIAP.Orchestration`

**[CMD]** `kubectl get pods -n fiap-games -w`

> O deploy autentica na Azure pelo mesmo OIDC, pega as credenciais do AKS e aplica. Olhem o comportamento do rollout: o pod novo sobe, fica Ready, e só depois o antigo morre. Os deployments estão com `maxUnavailable: 0`, então nunca há menos réplica pronta do que o esperado.

*(voltar na aba do curl)*

> E aqui está a prova: a aplicação respondeu durante todo o deploy. Só código 200. Nenhum erro, nenhuma requisição perdida.

*(mostrar a resposta com a alteração nova)*

> E a alteração que eu fiz agora está em produção.

---

## 4. Busca avançada — Lucas — 4:30

> A busca do catálogo não consulta mais o banco relacional. Ela consulta um índice no Elasticsearch. E a razão é simples: tem duas coisas que o SQL não sabe fazer.

**[CMD]** `curl -s "http://<IP>:8000/api/search?q=couter%20strke" | jq '.hits[] | {title, score}'`

> Eu digitei "couter strke", errado nos dois termos, e ele achou Counter-Strike. Isso é fuzzy search: o Elasticsearch aceita uma distância de edição, então erro de digitação continua encontrando o jogo. Um `LIKE` não encontraria nada.
>
> A segunda coisa é o campo `score`. A ordem dos resultados não é alfabética nem por id: é por relevância calculada. A consulta casa o termo contra cinco campos com pesos diferentes — o título vale quatro, gênero e desenvolvedora valem dois, publicadora um e meio, descrição um. E quem acerta o título exato recebe um reforço, para ficar acima de quem só acertou aproximado.

**[CMD]** `curl -s "http://<IP>:8000/api/search?q=witcher&genre=RPG&minPrice=50" | jq '.total'`

> Os filtros, como gênero e faixa de preço, entram numa cláusula separada: eles recortam o resultado sem pontuar, porque preço não deveria influenciar relevância.

*(criar ou editar um jogo pelo POST /api/game e repetir a busca)*

> E a sincronização: eu acabei de criar um jogo no SQL Server, e ele já aparece na busca. O serviço reindexa o documento depois de cada escrita, e remove do índice no delete. Se a indexação falhar, a escrita no banco **não** é desfeita — o jogo já foi gravado, e devolver erro faria o cliente achar que não foi. A falha vai para o log, e existe um endpoint de reindexação para reconciliar o índice inteiro.

*(opcional, se houver tempo: derrubar o pod do Elasticsearch e repetir a busca)*

> Uma decisão de projeto que vale explicar: com o Elasticsearch fora, a busca devolve 503. A gente não cai para uma consulta no SQL de propósito. Fuzzy e relevância não existem no relacional — entregar em silêncio uma busca sem nenhum dos dois seria enganar quem chamou.

---

## 5. Cache — Lucas — 3:30

> Agora o cache, e aqui dá para medir.

**[CMD]** `time curl -s "http://<IP>:8000/api/game/1" -H "Authorization: Bearer $TOKEN" > /dev/null`

**[CMD]** `time curl -s "http://<IP>:8000/api/game/1" -H "Authorization: Bearer $TOKEN" > /dev/null`

> A primeira chamada foi ao SQL Server. A segunda veio do Redis. Essa diferença é o que o cache faz por latência e por carga no banco — e lembrando que é cache distribuído: qualquer réplica da API aproveita o que outra gravou.

*(editar o jogo e repetir)*

> E a consistência: eu editei o jogo, e a resposta já vem atualizada. A escrita invalida as chaves do catálogo por prefixo, então não existe janela de dado velho.
>
> Tem um segundo uso de cache que eu acho mais interessante que o primeiro. A UsersAPI precisa de um token de serviço do Keycloak para administrar usuários. Sem cache, cada réplica abriria o próprio token a cada expiração. Com Redis, todas compartilham o mesmo, com TTL casado na expiração do token, menos uma margem de trinta segundos. É o caso de "dado de sessão" que o enunciado cita, e é compartilhado entre réplicas.

---

## 6. NoSQL — Matheus — 3:30

> O MongoDB entrou para o log de eventos do fluxo de compra, e eu quero explicar a decisão antes de mostrar.
>
> Quando alguém compra um jogo, o CatalogAPI publica um evento no Kafka, o PaymentAPI consome, processa o pagamento, publica o resultado, e o NotificationsAPI consome para notificar. Cada etapa grava o que passou por ela. Esse dado tem três características: cresce sem parar, o formato varia por tipo de evento, e nunca é alterado depois de escrito, só lido por correlação. É o caso em que o relacional dá trabalho e o documento resolve direto, sem migração de schema a cada campo novo.

**[CMD]** `curl -s "http://<IP>:8000/api/eventlog/$CORRELATION_ID" -H "Authorization: Bearer $TOKEN" | jq`

> Aqui está o rastro de uma compra: quatro eventos, publicado e consumido de cada lado, todos com o mesmo `correlationId` atravessando três microsserviços. Está na coleção `EventLogs` do Mongo, usando o driver oficial `MongoDB.Driver`, como o enunciado pede.
>
> O Mongo também guarda a auditoria do catálogo, pelo mesmo motivo.

---

## 7. Segurança e gestão de segredos — Bruno — 2:00

> Por último, segredos. O enunciado pede zero credenciais no código-fonte e nos YAML. A verificação é esta:

**[CMD]** `git grep -nE "Password|ClientSecret" -- '*.json' '*.yaml'`

> Vazio. Nos cinco repositórios. Não tem connection string, não tem senha de banco, não tem client secret do Keycloak em arquivo versionado. O que existe é um script que lê um `.env` fora do Git e cria os Secrets no cluster, e os pods recebem isso por `envFrom` em tempo de execução.

**[CMD]** `kubectl get secrets -n fiap-games`

> São cinco Secrets, nenhum deles com manifesto versionado.
>
> E, do lado da pipeline, o princípio é o mesmo levado um passo adiante: além de não haver credencial no código, não há credencial de nuvem no GitHub. A identidade que a pipeline assume tem exatamente três permissões: publicar imagem no registry, obter credencial do cluster, e escrever **apenas dentro do namespace** da aplicação. Ela não consegue mexer em RBAC, nem em outro namespace, nem no `kube-system`.

---

## 8. Encerramento — Bruno — 1:00

> Fechando: infraestrutura gerenciada na Azure com AKS e registry privado, CI/CD completo com build, teste, scan de vulnerabilidade, imagem versionada e deploy sem downtime, persistência poliglota com MongoDB e Redis, busca avançada com fuzzy e relevância no Elasticsearch, e nenhuma credencial versionada.
>
> Uma ressalva honesta: o Elasticsearch roda como workload dentro do AKS, e não como serviço gerenciado tipo Elastic Cloud ou OpenSearch, que é o que o enunciado sugere. O Marketplace da Azure está bloqueado nessa subscription de estudante. A aplicação já está preparada para o endpoint gerenciado — URL e chave vêm de configuração —, então a troca não exige mudança de código.
>
> O README do repositório de orquestração tem o detalhamento de cada parte, e o relatório de entrega tem os links. Obrigado.
