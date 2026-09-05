# SETUP — o que só você pode fazer

Este arquivo lista o que **não dá para automatizar de dentro do repositório**:
criação de app, chaves privadas, proteção de branch e integrações externas.
Tudo aqui exige uma decisão sua ou uma credencial que só você tem.

Ordem recomendada: 1 → 2 → 3 → 4 → 5 → 6. O passo 3 depende de as branches
`dev` e `hom` já existirem, o que acontece na primeira execução do
`rebuild-env`. O passo 6 só importa no dia da apresentação.

Substitua `<OWNER>/<REPO>` por `mathewsjts/derivative-environments` (ou deixe o
`gh` inferir, se estiver dentro do repo).

---

## 1. GitHub App  ⚠️ obrigatório — nada funciona sem ele

### Por que o `GITHUB_TOKEN` padrão não serve

O `GITHUB_TOKEN` que o Actions injeta em todo workflow tem uma restrição
deliberada do GitHub: **um push feito com ele não dispara workflows.** É uma
proteção contra recursão infinita (um job que faz push e redispara a si mesmo).

Neste modelo, o deploy é disparado por push na branch de ambiente. Ou seja:

```
push com GITHUB_TOKEN  →  a branch dev/hom atualiza normalmente        ✅
                       →  o deploy que reage ao push nunca roda        ❌
                       →  mensagem de erro                             nenhuma
```

**A falha é silenciosa.** Não há log, não há job vermelho, não há aviso. Você só
descobre abrindo o ambiente e percebendo que ele está velho — provavelmente
depois de alguém reclamar que "a feature não subiu".

Token de **GitHub App** não tem essa restrição: push feito por App dispara
workflows normalmente. É a única razão de existir um App aqui, e é por isso que
o `rebuild-env.yml` **falha explicitamente** se `APP_ID` ou `APP_PRIVATE_KEY`
estiverem ausentes, em vez de cair para o `GITHUB_TOKEN`.

O workflow `fake-deploy.yml` existe para provar isso ao vivo: se ele aparecer na
aba Actions depois de uma reconstrução, o token está certo.

### Criar

1. Abra <https://github.com/settings/apps/new>
2. **GitHub App name**: `derivative-env-bot` (qualquer nome único serve)
3. **Homepage URL**: a URL do repositório
4. **Webhook**: **desmarque** `Active` — este App não recebe eventos
5. **Repository permissions**:

   | Permissão | Nível | Para quê |
   |---|---|---|
   | Contents | **Read and write** | push com `--force-with-lease` em `dev` e `hom`, e a expiração diária em `env-resolutions` |
   | Pull requests | **Read and write** | comentar e aplicar/remover labels |
   | Metadata | Read-only | obrigatória, o GitHub adiciona sozinho |

6. **Where can this GitHub App be installed?** → `Only on this account`
7. **Create GitHub App**

### Instalar e coletar as credenciais

1. Na página do App, anote o **App ID** (número no topo).
2. **Install App** → sua conta → **Only select repositories** → este repositório.
3. De volta em **General** → **Private keys** → **Generate a private key**.
   Baixa um `.pem`. Ele **não pode ser recuperado depois** — guarde ou gere outro.

```bash
gh secret set APP_ID --body "<o numero do App ID>"
gh secret set APP_PRIVATE_KEY < ~/Downloads/derivative-env-bot.*.private-key.pem

gh secret list          # esperado: APP_ID, APP_PRIVATE_KEY
```

> O `.pem` é uma chave privada. Não commite, e apague do `~/Downloads` depois.

---

## 2. Labels

Cinco labels, duas famílias com papéis bem diferentes:

**Intenção** — aplicada por pessoas:

- `deploy:dev` / `deploy:hom` — "quero esta branch no conjunto deste ambiente."
- `priority:high` — "em caso de conflito, esta branch entra antes das outras."
  É **global**: vale em todo ambiente onde o PR já tem `deploy:*`. Sozinha não
  faz nada — sem `deploy:*` o PR nem é candidato. E ela **não resolve conflito**,
  só decide quem fica com a vaga: o perdedor sai do ambiente até o conflito
  deixar de existir, exatamente como qualquer outra exclusão.

**Estado** — aplicada e removida só pelo job:

- `blocked:dev` / `blocked:hom` — é o único "banco de dados" do modelo: é por
  causa dela que o job sabe se já comentou um conflito, sem guardar estado em
  lugar nenhum. **Não aplique a mão.**

```bash
./scripts/create-labels.sh
```

O script usa `gh label create --force`, então pode rodar quantas vezes quiser.

**Continuam sendo cinco.** As resoluções gravadas (seção 3c) deliberadamente
**não** ganharam label: `blocked:<env>` significa *fora do ambiente*, e quem
entra por uma resolução está **dentro** — marcar seria tornar a label uma
mentira e quebrar a limpeza de marcas órfãs do `notify.sh`. A memória desse
estado é o marcador invisível no corpo do comentário, que sempre foi a memória
de verdade do sistema; a label é o atalho barato para o caso comum.

---

## 3. Branch protection

Rode **depois** da primeira reconstrução — as branches precisam existir.

Usamos **rulesets**, não branch protection clássica: em repositório de conta
pessoal, o "Restrict who can push" clássico não existe (é só para organização).
Ruleset funciona em repo pessoal público e aceita GitHub App como bypass actor.

### 3a. `dev` e `hom` — ninguém escreve, exceto o App

Troque `<SEU_APP_ID>` pelo número do App ID do passo 1 (é um número, sem aspas).

```bash
gh api -X POST repos/<OWNER>/<REPO>/rulesets \
  --input - <<JSON
{
  "name": "ambientes derivados (dev, hom)",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["refs/heads/dev", "refs/heads/hom"], "exclude": [] }
  },
  "bypass_actors": [
    { "actor_id": <SEU_APP_ID>, "actor_type": "Integration", "bypass_mode": "always" }
  ],
  "rules": [
    { "type": "creation" },
    { "type": "update" },
    { "type": "deletion" },
    { "type": "non_fast_forward" }
  ]
}
JSON
```

O que isso faz, e por que cada regra está aí:

| Regra | Efeito | Por quê |
|---|---|---|
| `creation` | ninguém cria a branch | ambiente só nasce derivado |
| `update` | ninguém faz push | **o ponto todo**: `dev`/`hom` deixam de receber merge humano |
| `deletion` | ninguém apaga | evita apagar um ambiente por engano |
| `non_fast_forward` | ninguém faz force-push | o histórico é reescrito só pelo job |

O App tem `bypass_mode: always`, então ele — e só ele — faz as quatro coisas.
**Nenhum PR é exigido**: não existe PR para uma branch derivada.

Para confirmar que funcionou (deve ser **rejeitado**):

```bash
git push --force origin main:hom
# remote: Repository rule violations found ...
```

### 3b. `main` — gates verdes e 1 approve

```bash
gh api -X POST repos/<OWNER>/<REPO>/rulesets \
  --input - <<'JSON'
{
  "name": "main protegida",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "gates do PR" },
          { "context": "SonarCloud" }
        ]
      }
    }
  ]
}
JSON
```

> ### ⚠️ Se este ruleset já existe, a ordem importa
>
> O ruleset exige status checks **por nome**. Até o `pr-gates.yml` deste PR
> chegar na `main`, os nomes que reportam são os cinco antigos:
>
> ```
> typecheck / lint / testes
> npm audit (producao)
> docker build (gate)
> SonarCloud
> sincronia com a main
> ```
>
> Depois do merge passam a ser dois: `gates do PR` e `SonarCloud`. Contexto
> exigido que nunca reporta **nunca fica verde** — se o ruleset for atualizado
> na ordem errada, todo PR aberto trava esperando um check que não existe mais,
> inclusive o PR que faz a mudança.
>
> **Atualize o ruleset imediatamente antes de mergear**, com os dois nomes
> novos. Enquanto os workflows antigos ainda estiverem na `main`, `gates do PR`
> fica pendente — por isso é "imediatamente antes", e não "com antecedência".
>
> Pelo browser: **Settings → Rules → `main protegida` → Require status checks**.
> Ou, com os dois nomes de uma vez, via API — ver o bloco de comando logo
> abaixo de "Migrar os status checks exigidos".

### O `strict` fica **desligado**, e isso é uma decisão

`"strict_required_status_checks_policy": false` acima não é descuido. É a
escolha, e ela tem um custo — que fica escrito aqui justamente para ninguém
"consertar" o valor sem saber o que está desfazendo.

`strict` quer dizer *a branch precisa estar atualizada com a `main` para
mergear*. O que ele compra é **prevenção**: nenhum PR entra sem ter sido
validado contra a `main` exata que vai recebê-lo. O que ele cobra é **O(N)**:
cada push na `main` invalida os N PRs abertos de uma vez, e cada um precisa de
uma atualização — que é um push, que dispara os gates e uma reconstrução de
ambiente. Com 30 PRs abertos, um merge vira ~30 rodadas de CI. A conta cresce
com o número de PRs abertos, não com o tamanho do time.

E o que a `main` precisa não é que todo PR esteja em dia com ela. É **saber em
~60 segundos quando alguma coisa quebrou** — e isso ela não tinha: até este PR
não existia CI nenhum na `main`, porque o `pr-gates.yml` só rodava em
`pull_request`. O único sinal pós-merge era o `docker build` do `rebuild-env`,
que apenas compila (o Dockerfile instala `typescript` e mais nada, sem `vitest`
e sem `eslint`, de propósito).

| | custo por merge | o que garante |
|---|---|---|
| prevenção — `strict` ligado | O(N × PRs abertos) | nenhum PR mergeia desatualizado |
| detecção — gates na `main` | O(1): 2 jobs | `main` quebrada aparece em ~60s |

**O que a escolha custa, dito explicitamente.** Existe uma janela: um PR pode
mergear tendo sido validado contra uma `main` anterior. Dois PRs verdes
separados podem produzir uma `main` vermelha — conflito **semântico**, não
textual: o git mergeia limpo e o teste quebra. Quando isso acontecer, o preço é
**um PR de correção**, aberto por quem viu o `gates do PR` vermelho na `main`
um minuto depois do merge. O preço da outra coluna era pagar ~30 rodadas de CI
em todo merge para comprar essa janela — e, do jeito que estava montado aqui,
sem sequer comprá-la (ver o parágrafo seguinte).

**Meia-`strict` é pior que nenhuma.** O job `sincronia com a main` roda em
evento de PR: ele é um *retrato do momento do último push*. Quando a `main`
anda depois disso, ele não re-executa e continua verde, com o PR já
desatualizado. Enquanto ele era um passo capaz de reprovar o `gates do PR` —
que é contexto exigido pelo ruleset — o efeito era travar o merge conforme o
último push viu, sem garantir nada continuamente, e ainda pagando o `sync-prs`.
Por isso ele virou **aviso**: continua rodando e continua explicando o rebase
(é a mensagem que o bloco 5 do DEMO usa), mas não derruba mais o job. Ver o
comentário dele em [pr-gates.yml](.github/workflows/pr-gates.yml).

Se você já criou o ruleset com `strict` ligado, desligue em **Settings → Rules
→ `main protegida` → Require status checks to pass** e desmarque *Require
branches to be up to date before merging*.

> Se um dia o número justificar prevenção de novo, o caminho não é religar o
> `strict` sozinho: é **merge queue**, que dá a mesma garantia sem multiplicar
> por N. Ela está na lista do que este modelo não tem de propósito (README), e
> essa lista é para ser revisada com dado medido, não com opinião.

### Migrar os status checks exigidos

Troca os cinco contextos antigos pelos dois novos **sem recriar o ruleset** —
recriar perderia `bypass_actors` e as outras regras. Rode **imediatamente antes
de mergear** o PR que junta os jobs do `pr-gates`:

```bash
OWNER_REPO=mathewsjts/derivative-environments

# 1. Achar o ruleset pelo nome
RULESET_ID=$(gh api "repos/$OWNER_REPO/rulesets" \
  --jq '.[] | select(.name == "main protegida") | .id')
echo "ruleset: $RULESET_ID"

# 2. Baixar inteiro e trocar SO a lista de contextos
gh api "repos/$OWNER_REPO/rulesets/$RULESET_ID" > /tmp/ruleset.json

jq '{name, target, enforcement, conditions, bypass_actors,
     rules: [ .rules[]
              | if .type == "required_status_checks"
                then .parameters.required_status_checks =
                     [ { "context": "gates do PR" }, { "context": "SonarCloud" } ]
                else . end ]}' /tmp/ruleset.json > /tmp/ruleset-novo.json

# 3. Conferir o corpo ANTES de enviar
jq -r '.rules[] | select(.type == "required_status_checks") | .parameters
       | "strict: \(.strict_required_status_checks_policy)",
         "contextos: \([.required_status_checks[].context] | join(" | "))"' \
  /tmp/ruleset-novo.json

# 4. Enviar
gh api -X PUT "repos/$OWNER_REPO/rulesets/$RULESET_ID" --input /tmp/ruleset-novo.json
```

> `--input` com o JSON inteiro, e não `-F rules=@arquivo`: `-F` mandaria a lista
> de regras como **string** e o ruleset ficaria inválido.

> **Confira o `strict` no passo 3.** O esperado é `strict: false`, pela decisão
> escrita acima. Se o passo 3 imprimir `strict: true`, o ruleset ativo diverge
> deste arquivo — e cada merge na `main` está invalidando todos os PRs abertos
> de uma vez. É uma decisão sua, e este comando **preserva** o valor que estiver
> lá: ele troca só a lista de contextos.

> **O `sync-prs` não morreu junto com o `strict`.** Sem `strict`, o que sobra
> dele é "integre cedo, em pedaços pequenos" — benefício real, mas incremental,
> que não precisa acontecer a cada merge. Por isso ele deixou de rodar a cada
> push na `main` e passou a rodar **uma vez por dia**, às 06:00 UTC, junto com o
> `label-ttl` — mais o disparo manual, que continua. A amplificação cai de
> O(merges × PRs) para O(1/dia). Não precisa de configuração nova: usa o mesmo
> GitHub App do passo 1.

> **Na demo, com 1 approve exigido e só você na sala:** você não consegue aprovar
> o próprio PR. Ou peça o approve a alguém antes de começar, ou faça o bloco 5
> com `enforcement: "evaluate"` neste ruleset, ou desligue temporariamente a
> regra `pull_request`. Decida isso **antes** de subir ao palco.

---

### 3c. `env-resolutions` — o ref das resoluções gravadas

Este ref só existe se alguém rodar `scripts/publish-resolution.sh`. **Não
precisa criar nada agora**, e a POC funciona inteira sem ele — o
`assemble-env.sh` desliga o `rerere` quando não encontra o ref e a montagem fica
byte a byte a de sempre.

O que ele é: um ref **órfão** (sem relação com a `main`) carregando o `rr-cache`
do `git rerere` — as resoluções que alguém gravou para pares de PRs que
conflitam. **Não é código.** Nada dele é buildado, e o único consumidor é a
montagem.

**Ele não recebe ruleset**, e a decisão é deliberada. As branches `dev` e `hom`
são protegidas porque escrever nelas à mão desfaz o modelo; aqui é o contrário:
escrever é o uso normal, feito por pessoas, pelo script. O controle está em
outro lugar — a resolução só tem efeito se um PR carregar `deploy:*`, e essa
label continua sendo o limite de confiança do modelo inteiro.

Quem escreve nele:

| Quem | Quando | Como |
|---|---|---|
| pessoa | grava uma resolução | `publish-resolution.sh`, com `--force-with-lease` |
| App | expira resoluções órfãs | `label-ttl.yml`, diário, também com lease |
| `rebuild-env` | **nunca** | ele só lê — ver abaixo |

O "nunca" é uma invariante testada (`test-workflows.sh`), e o motivo é concreto:
com `rerere` ligado, o próprio job **grava preimages** dos conflitos que *não*
resolveu. São inofensivos — preimage sem postimage não faz nada —, mas se o job
empurrasse o cache de volta, o ref viraria lixeira em duas semanas e a pergunta
"quais resoluções estão vivas?" deixaria de ter resposta.

Para inspecionar o que está gravado hoje:

```bash
git fetch origin env-resolutions
git ls-tree -r --name-only FETCH_HEAD | grep meta.json \
  | xargs -I{} git show FETCH_HEAD:{} | jq -s '.'
```

Para zerar tudo (o ambiente volta ao conjunto anterior, sem resíduo):

```bash
git push origin --delete env-resolutions
gh workflow run rebuild-env.yml -f environment=ambos
```

---

## 4. SonarCloud

O gate falha de propósito quando `SONAR_TOKEN` não existe. Um gate de qualidade
que fica verde por falta de credencial não é um gate — é um adesivo.

1. <https://sonarcloud.io> → login com GitHub → **Analyze new project**
2. Selecione este repositório (organização = seu usuário do GitHub)
3. **Administration → Analysis Method → desligue `Automatic Analysis`**
   (sem isso o scan do CI conflita com o automático e falha)
4. **My Account → Security → Generate Token**

```bash
gh secret set SONAR_TOKEN --body "<token>"
```

5. Confira em [sonar-project.properties](sonar-project.properties) se
   `sonar.projectKey` e `sonar.organization` batem com o que o SonarCloud mostra
   em **Administration → Update Key**. O padrão é `<org>_<repo>` e `<org>`.

### O quality gate não exige cobertura, e isso é uma decisão

O `Sonar way` — o gate padrão — exige **80% de cobertura em código novo**. Este
projeto **não gera relatório de cobertura**, por decisão de orçamento de CI
([sonar-project.properties](sonar-project.properties) explica).

As duas coisas juntas produzem uma armadilha que só aparece tarde. Enquanto os
PRs mexem em workflows, docs e declarações de tipo, não existe linha executável
nova, a condição nunca é avaliada, e o gate fica verde **por vácuo**. O primeiro
PR a adicionar código executável em `src/` toma `ERROR` com `new_coverage = 0%`
— e o código dele pode estar 100% coberto por teste. O gate estaria medindo a
ausência de um **relatório**, não a ausência de **teste**.

Aconteceu no PR #16. A saída escolhida foi **não exigir a métrica**, e a razão é
o escopo desta POC: ela existe para demonstrar um modelo de branching, e o papel
do Sonar aqui é provar que **existe um portão de qualidade travando o merge** —
não replicar fielmente a política de qualidade de um projeto real. Um projeto de
verdade faria o contrário: geraria o relatório.

O que **continua** reprovando, e é por isso que o gate não virou adesivo:

| Condição | Reprova quando |
|---|---|
| `new_reliability_rating` > 1 | bug novo |
| `new_security_rating` > 1 | vulnerabilidade nova |
| `new_maintainability_rating` > 1 | code smell novo |
| `new_duplicated_lines_density` > 3 | duplicação nova |
| `new_security_hotspots_reviewed` < 100 | hotspot não revisado |

**O `Sonar way` é built-in e não pode ser editado**, então o caminho é copiar,
remover uma condição e associar a cópia ao projeto.

Pela UI: **Quality Gates → Sonar way → Copy** → nomeie `POC sem coverage` →
remova a condição `Coverage on New Code` → **Projects → Add** este projeto.

Pela API, com um token de administração da organização (o `SONAR_TOKEN` que está
no `gh secret` serve para o scan, mas confira se ele tem permissão de admin):

```bash
SONAR_TOKEN=<seu token>
ORG=mathewsjts
KEY=mathewsjts_derivative-environments
GATE="POC sem coverage"

sonar() { curl -s -u "$SONAR_TOKEN:" "$@"; }

# 1. Copia o built-in.
sonar -X POST "https://sonarcloud.io/api/qualitygates/copy" \
  --data-urlencode "sourceName=Sonar way" \
  --data-urlencode "name=$GATE" \
  --data-urlencode "organization=$ORG"

# 2. Remove SO a condicao de cobertura.
ID=$(sonar "https://sonarcloud.io/api/qualitygates/show?organization=$ORG&name=$GATE" \
     | jq -r '.conditions[] | select(.metric == "new_coverage") | .id')
sonar -X POST "https://sonarcloud.io/api/qualitygates/delete_condition" \
  --data-urlencode "id=$ID" --data-urlencode "organization=$ORG"

# 3. Associa ao projeto.
sonar -X POST "https://sonarcloud.io/api/qualitygates/select" \
  --data-urlencode "gateName=$GATE" \
  --data-urlencode "projectKey=$KEY" \
  --data-urlencode "organization=$ORG"

# 4. Confere o que sobrou em pe.
sonar "https://sonarcloud.io/api/qualitygates/show?organization=$ORG&name=$GATE" \
  | jq -r '.conditions[] | "  \(.metric) \(.op) \(.error)"'
```

> Os comandos acima não foram executados na configuração deste repositório —
> o `SONAR_TOKEN` é secret do GitHub e não pode ser lido de volta. Se algum
> parâmetro tiver mudado na API do SonarCloud, o caminho pela UI resolve igual.

Depois, para o PR aberto reavaliar com o gate novo — um analysis novo é o que
atualiza o check:

```bash
gh run rerun "$(gh run list --branch <branch> --workflow pr-gates --limit 1 \
  --json databaseId --jq '.[0].databaseId')"
```

> **Não confunda os dois checks com nome parecido.** `SonarCloud` é o *job* do
> `pr-gates.yml` e está na lista de contextos exigidos pelo ruleset
> (seção 3b). `SonarCloud Code Analysis` é o check do app do SonarCloud, que
> reporta o quality gate e **não** é exigido — foi por isso que o PR #16
> continuou mergeável com ele vermelho. Se você quiser que o gate de qualidade
> realmente trave o merge, adicione `SonarCloud Code Analysis` aos contextos
> exigidos do ruleset.

---

## 5. Vercel

A Vercel **não usa o Dockerfile** deste repositório — ela roda `api/index.ts`
como função serverless. O `docker build` é gate de CI. Não tente fazer a Vercel
buildar o Dockerfile.

1. <https://vercel.com/new> → importe o repositório
2. **Framework Preset**: `Other`
3. **Root Directory**: `./`
4. **Build and Output Settings**: não mexa. O [vercel.json](vercel.json) já
   define `buildCommand` e `outputDirectory`, e o que está no arquivo tem
   precedência sobre o que estiver no dashboard.
5. **Deploy**

> **Se aparecer `Error: No Output Directory named "public" found`:** é o
> zero-config da Vercel. Ele detecta o script `build` do `package.json`, roda
> `tsc`, e depois procura uma pasta estática — que esta POC não tem, porque a
> API inteira é uma Serverless Function.
>
> O repositório já resolve isso: `vercel.json` declara um `buildCommand` que não
> faz nada e um `outputDirectory` apontando para `public/`, que existe e está
> vazia de propósito. Se o erro persistir, confira em **Settings → Build and
> Deployment** se alguém marcou **Override** em *Output Directory* — um override
> no dashboard com valor vazio vence o `vercel.json`. Desmarque.
>
> A pasta `public/` fica vazia porque o filesystem é consultado **antes** dos
> rewrites: um `index.html` ali passaria a responder `GET /` no lugar da API, e
> é justamente `/` que o bloco 1 do DEMO.md abre no browser.
>
> **Não coloque comentários no `vercel.json`.** O schema da Vercel é estrito e
> rejeita qualquer propriedade que não conheça — inclusive a convenção `"//"`
> usada para comentar JSON. O erro é
> `schema validation failed ... should NOT have additional property "//"`.

Depois do primeiro deploy:

6. **Settings → Git**: confirme que a **Production Branch** é `main` e que
   *todas* as outras branches geram Preview Deployment (é o padrão). São os
   previews de `dev` e `hom` que a demo usa.
7. As URLs de preview são estáveis por branch:

```
https://<projeto>-git-dev-<escopo>.vercel.app/version
https://<projeto>-git-hom-<escopo>.vercel.app/version
```

8. Grave as URLs como variáveis do repositório. O `rebuild-env` usa isso para
   colocar o link do ambiente dentro do comentário do PR:

```bash
gh variable set VERCEL_URL_DEV --body "https://<projeto>-git-dev-<escopo>.vercel.app"
gh variable set VERCEL_URL_HOM --body "https://<projeto>-git-hom-<escopo>.vercel.app"
```

> **Verifique no primeiro deploy:** `api/index.ts` importa de `../src/app`, fora
> da pasta `api/`. O bundler da Vercel resolve isso sozinho. Se por algum motivo
> reclamar, abra `/version` no preview de `main` antes de qualquer outra coisa —
> é o teste mais rápido de que o entrypoint funciona.

Force-push também dispara deploy na Vercel. É exatamente disso que o modelo
depende: quem empurra `dev`/`hom` é o job.

---

## 6. `ENABLE_FAKE_DEPLOY` — ligue antes da demo

O `fake-deploy.yml` é o workflow que **prova ao vivo** que push feito por
GitHub App dispara workflows (§1). Ele roda a cada push em `dev`/`hom`, que é o
desfecho normal de quase todo evento do modelo: 36 jobs de ~5 segundos, ou seja
36 minutos faturados para 3 minutos de computação real — o GitHub arredonda por
job.

Fora da apresentação ele não verifica nada que já não esteja verificado. Por
isso ele fica **desligado por padrão** e só roda quando a variável de
repositório `ENABLE_FAKE_DEPLOY` valer exatamente `true`. Job pulado não é
faturado.

```bash
gh variable set ENABLE_FAKE_DEPLOY --body true     # antes da demo
gh variable set ENABLE_FAKE_DEPLOY --body false    # depois
```

> ⚠️ **O bloco 2 do DEMO.md depende dela.** É lá que você mostra o
> `fake-deploy` tendo rodado logo depois da reconstrução — o item que prova que
> o token está certo. Com a variável desligada o job aparece como *skipped*, e o
> argumento fica sem o que apontar na tela. Ligue no T-10, junto com o resto da
> preparação, e confirme com `gh variable list`.

---

## 7. Checklist antes da demo

```bash
gh secret list        # APP_ID, APP_PRIVATE_KEY, SONAR_TOKEN
gh variable list      # VERCEL_URL_DEV, VERCEL_URL_HOM, ENABLE_FAKE_DEPLOY=true
gh label list         # deploy:dev, deploy:hom, priority:high, blocked:dev, blocked:hom
gh ruleset list       # 2 rulesets ativos (env-resolutions NAO tem, ver 3c)

# O gate do Sonar nao pode exigir cobertura (ver 4). Esperado: sem new_coverage.
curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=mathewsjts_derivative-environments" \
  | jq -r '.projectStatus.conditions[].metricKey'

# Opcional: se nao existir, tudo funciona igual e o rerere fica desligado.
git ls-remote origin refs/heads/env-resolutions

./.github/scripts/test-assemble.sh   # a montagem, offline, ~5s
./.github/scripts/test-workflows.sh  # invariantes de concorrência dos workflows
./scripts/seed-demo.sh               # 3 PRs + primeira reconstrução
gh run list --limit 5                # rebuild-env e fake-deploy verdes
```

E abra as duas URLs da Vercel para conferir que respondem:

- `dev` deve mostrar `main + feat/a-user-endpoint + feat/c-metrics-endpoint`
- `hom` deve mostrar `main`

Se as duas responderem, você está pronto. O roteiro está em [DEMO.md](DEMO.md).
