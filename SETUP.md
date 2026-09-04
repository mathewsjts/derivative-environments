# SETUP — o que só você pode fazer

Este arquivo lista o que **não dá para automatizar de dentro do repositório**:
criação de app, chaves privadas, proteção de branch e integrações externas.
Tudo aqui exige uma decisão sua ou uma credencial que só você tem.

Ordem recomendada: 1 → 2 → 3 → 4 → 5. O passo 3 depende de as branches `dev` e
`hom` já existirem, o que acontece na primeira execução do `rebuild-env`.

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
   | Contents | **Read and write** | push com `--force-with-lease` em `dev` e `hom` |
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

Quatro labels, duas famílias com papéis bem diferentes:

- `deploy:dev` / `deploy:hom` — **intenção**, aplicada por pessoas.
  "Quero esta branch no conjunto deste ambiente."
- `blocked:dev` / `blocked:hom` — **estado**, aplicada e removida só pelo job.
  É o único "banco de dados" do modelo: é por causa dela que o job sabe se já
  comentou um conflito, sem guardar estado em lugar nenhum. **Não aplique a mão.**

```bash
./scripts/create-labels.sh
```

O script usa `gh label create --force`, então pode rodar quantas vezes quiser.

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
          { "context": "typecheck / lint / testes" },
          { "context": "npm audit (producao)" },
          { "context": "docker build (gate)" },
          { "context": "SonarCloud" },
          { "context": "sincronia com a main" }
        ]
      }
    }
  ]
}
JSON
```

`strict_required_status_checks_policy` fica **desligado** de propósito: o job
`sincronia com a main` já reprova branch desatualizada, com uma mensagem que
explica o que fazer. A versão nativa do GitHub só enfileira o merge, sem dizer
nada.

> **Na demo, com 1 approve exigido e só você na sala:** você não consegue aprovar
> o próprio PR. Ou peça o approve a alguém antes de começar, ou faça o bloco 5
> com `enforcement: "evaluate"` neste ruleset, ou desligue temporariamente a
> regra `pull_request`. Decida isso **antes** de subir ao palco.

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

## 6. Checklist antes da demo

```bash
gh secret list        # APP_ID, APP_PRIVATE_KEY, SONAR_TOKEN
gh variable list      # VERCEL_URL_DEV, VERCEL_URL_HOM
gh label list         # deploy:dev, deploy:hom, blocked:dev, blocked:hom
gh ruleset list       # 2 rulesets ativos

./.github/scripts/test-assemble.sh   # 29 verificações, offline, ~5s
./scripts/seed-demo.sh               # 3 PRs + primeira reconstrução
gh run list --limit 5                # rebuild-env e fake-deploy verdes
```

E abra as duas URLs da Vercel para conferir que respondem:

- `dev` deve mostrar `main + feat/a-user-endpoint + feat/c-metrics-endpoint`
- `hom` deve mostrar `main`

Se as duas responderem, você está pronto. O roteiro está em [DEMO.md](DEMO.md).
