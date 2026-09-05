# DEMO — 20 minutos

> **A tese, em uma frase:** `dev` e `hom` deixam de ser branches que recebem
> merge e viram **artefatos derivados** — reconstruídos do zero a partir da
> `main` mais os PRs marcados por label. Um PR por feature, zero cherry-pick,
> e conflito de uma branch não trava o ambiente das outras.

| # | Bloco | Tempo | Termina quando |
|---|---|---|---|
| 0 | Preparação (antes de subir ao palco) | T-10 | duas URLs da Vercel respondendo |
| 1 | Estado inicial | 2 min | plateia viu `hom` = `main` |
| 2 | Montar `hom` ao vivo | 3 min | `/version` mostra `main + a + c` |
| 3 | O conflito de B | 4 min | comentário lido em voz alta |
| 3b | _(opcional)_ B é crítica: `priority:high` | 2 min | `hom` inverte, A sai |
| 4 | Push de correção em A | 3 min | reconstruiu sem re-labelar nada |
| 5 | Merge de A na `main` | 4 min | B volta, comentário "✅" |
| 6 | O gate antes da `main` | 2 min | PR de lint vermelho |
| 7 | Fechamento | 2 min | — |

**Deixe abertas, em abas fixas:** os 3 PRs · a aba Actions · `/version` de `hom`
· `/version` de `dev` · um terminal no repositório.

---

## 0. Preparação — T-10 min

> **Pré-requisito:** [SETUP.md](SETUP.md) inteiro concluído. Sem o GitHub App
> (§1) o `rebuild-env` falha de propósito e as branches `dev`/`hom` nem chegam a
> existir — não há o que mostrar na Vercel.

```bash
gh variable set ENABLE_FAKE_DEPLOY --body true   # ⚠️ o bloco 2 depende disto
./.github/scripts/test-assemble.sh    # a montagem, offline, ~5s
./.github/scripts/test-workflows.sh   # invariantes de concorrência
./scripts/seed-demo.sh                # 3 PRs + primeira reconstrução
gh run list --limit 5                 # rebuild-env e fake-deploy verdes
```

> **`ENABLE_FAKE_DEPLOY` não é detalhe de configuração.** O `fake-deploy` fica
> desligado por padrão porque custa 36 minutos faturados para 3 de computação
> (SETUP.md §6). Desligado, o job aparece como *skipped* e o bloco 2 — o item
> que prova que o push do App dispara workflows — fica sem o que apontar na
> tela. Ligue agora, confirme com `gh variable list`, e desligue depois da
> apresentação.

Deixe a branch do bloco 6 **empurrada, mas sem PR** — assim ela não aparece como
um quarto PR no bloco 1, e abrir o PR ao vivo custa um comando:

```bash
git checkout -b feat/d-lint-error origin/main
printf '\nconst naoUsado = "isto reprova no lint";\n' >> src/routes/health.ts
git commit -aqm "feat(health): variavel nao usada, de proposito"
git push -q -u origin feat/d-lint-error
git checkout -q main
```

Confira as duas URLs (SETUP.md §5). Estado esperado:

- `dev` → `main + feat/a-user-endpoint + feat/c-metrics-endpoint`
- `hom` → `main`

> Se `main` exige 1 approve e você está sozinho, resolva **agora** — o bloco 5
> depende de mergear um PR. Ver a nota no fim de SETUP.md §3b.

---

## 1. Estado inicial — 2 min

**Mostrar:** a lista de PRs.

```bash
gh pr list --state open --base main
```

> Três features, três PRs, todos para a `main`. **Não existe PR para `dev`, não
> existe PR para `hom`.** No modelo de hoje, cada uma dessas features viraria
> até três PRs — um por ambiente — e o review aconteceria na branch de
> homologação.

**Mostrar:** `/version` de `hom` no browser.

```json
{ "environment": "hom", "summary": "main", "features": [], "excluded": [] }
```

> `hom` está vazia: hoje ela é exatamente a `main`. E `dev` já tem duas features
> dentro — mesmo mecanismo, montado antes de vocês chegarem. Vou montar `hom`
> do zero, aqui, agora.

**Mostrar rapidamente:** `src/routes/index.ts` na `main`, os blocos de
marcadores. Esse é o arquivo em que as três features escrevem.

---

## 2. Montar `hom` ao vivo — 3 min

**Fazer:** aplicar `deploy:hom` nos PRs de **A** e **C**, pelo browser (é mais
legível para a plateia do que um comando).

> PR #1 → Labels → `deploy:hom`. PR #3 → Labels → `deploy:hom`.

Ou, se preferir terminal:

```bash
gh pr edit 1 --add-label deploy:hom
gh pr edit 3 --add-label deploy:hom
```

**Enquanto o job roda (~90s), diga:**

> Ninguém fez merge em `hom`. Ninguém abriu um PR para `hom`. O que essas duas
> pessoas fizeram foi declarar uma **intenção**: "quero minha branch no próximo
> `hom`". O job faz o resto — `reset` na `main` de agora e reaplica as branches
> marcadas, na ordem do número do PR.
>
> E ele monta em dois passes: primeiro descobre quem mergeia limpo, depois
> remonta o conjunto do zero com datas fixas. Por causa disso, rodar duas vezes
> seguidas sem mudança nenhuma dá **exatamente o mesmo SHA** — e o job nem
> publica, porque não há o que publicar.

**Mostrar:** a aba Actions, o resumo do job `reconstruir hom` (tabela com ✅/⛔).

**Mostrar:** `/version` de `hom` — agora `main + feat/a-user-endpoint +
feat/c-metrics-endpoint`.

**Mostrar — este é o item que prova o token:** o workflow **`fake-deploy`**
rodou logo depois. (Se ele aparecer *skipped*, `ENABLE_FAKE_DEPLOY` não está
`true` — volte ao bloco 0.)

> Repare que existe um segundo job aqui. Ele rodou porque o push em `hom` foi
> feito por um **GitHub App**. Se eu tivesse usado o `GITHUB_TOKEN` padrão do
> Actions, o push teria funcionado, a branch teria atualizado, e **o deploy
> simplesmente não rodaria** — sem erro, sem log, sem aviso. O GitHub bloqueia
> workflows disparados pelo token dele mesmo, para evitar recursão. É a falha
> mais silenciosa deste modelo inteiro, e é por isso que ela tem um workflow só
> para ficar visível.

---

## 3. O conflito de B — 4 min

**Fazer:** aplicar `deploy:hom` no PR de **B**.

```bash
gh pr edit 2 --add-label deploy:hom
```

**Enquanto o job roda (~90s), diga:**

> B registra a rota dela **no mesmo ponto** de `src/routes/index.ts` que A. As
> duas conflitam. A pergunta que interessa é: o que acontece com `hom`?
>
> No modelo de hoje, alguém resolveria esse conflito na branch de homologação, e
> aí `hom` passaria a ter um commit que não existe em lugar nenhum. Ou pediria
> para B rebasear em cima de A — e a branch de B passaria a carregar código de
> uma feature que talvez nunca seja mergeada.

**Mostrar:** o resumo do job — A e C com ✅, B com ⛔.

**Mostrar:** `/version` de `hom`. **Continua `main + a + c`**, e agora o campo
`excluded` traz B, com o motivo e o arquivo.

> O ambiente não caiu, não travou, não ficou pela metade. A exclusão é
> **cirúrgica**: B ficou de fora, A e C seguem no ar. Quem não conflita não
> paga o preço de quem conflita.

**Mostrar:** o comentário no PR #2. **Leia em voz alta**, inteiro. E pare nesta
linha:

> ### **"Nada a fazer no seu PR: ele continua limpo."**
>
> Essa linha é a parte mais importante do comentário. Sem ela, a primeira pessoa
> que recebe esse aviso vai tentar resolver o conflito na branch dela — que é
> exatamente o que este modelo elimina. `hom` é descartável. Resolver conflito
> ali, ou por causa dali, é trabalho jogado fora.

**Mencione:** a label `blocked:hom` que apareceu no PR.

> Isso é a marca de estado. O job comenta **uma vez**, em transição. Enquanto o
> conflito persistir, silêncio absoluto — pode rodar vinte vezes, não sai um
> segundo comentário. Não existe banco de dados nisso: o estado mora na label.

---

## 3b. _(opcional)_ B é crítica: `priority:high` — 2 min

> Corte este bloco primeiro se estiver atrasado. Ele responde à pergunta que a
> plateia costuma fazer no bloco 3 — **"e se a branch que ficou de fora for a
> importante?"** — então vale ter na manga mesmo sem apresentar.

**Fazer:**

```bash
gh pr edit 2 --add-label priority:high
```

**Enquanto o job roda, diga:**

> Até agora a ordem foi o número do PR: quem abriu antes entra antes. É estável
> e ninguém precisa negociar. Mas é cega ao que ficou de fora — se B for o
> ajuste crítico que precisa ser testado hoje, ela está presa atrás de um PR
> mais antigo, e a única saída seria tirar a label de A na mão.

**Mostrar:** `/version` de `hom` — agora **`main + b + c`**, e é **A** que
aparece em `excluded`, com `conflictsWith` apontando para o PR #2.

**Mostrar:** o comentário no PR #1, que diz *contra quem* e *por quê*:

> **Conflitou com:** #2 `feat/b-auth-endpoint` (@grace) — marcada com
> `priority:high`, por isso entrou no conjunto antes da sua.

> Repare no que **não** mudou. Nenhuma branch foi tocada. A label não resolve
> conflito nenhum: ela decide quem fica com a vaga. A que perde sai do ambiente
> e volta sozinha quando o conflito deixar de existir — o mesmo mecanismo do
> bloco 3, com os papéis trocados.

**Fazer, para voltar ao estado do bloco 3** (necessário para o bloco 4 seguir o
roteiro):

```bash
gh pr edit 2 --remove-label priority:high
```

> E some sem deixar resíduo: tirar a label devolve **o mesmo SHA** de ambiente
> de antes. Prioridade é ordenação, não um estado que alguém precisa limpar.

---

## 3c. _(opcional)_ A e B ao mesmo tempo: resolução gravada — 3 min

> Corte junto com o 3b se estiver atrasado. Este bloco responde à **segunda**
> pergunta que a plateia faz no bloco 3 — *"e se eu precisar testar as duas ao
> mesmo tempo, com dois QAs diferentes?"* — que é a pergunta de quem tem um
> ambiente só e não vai ganhar outro.

**Diga primeiro, antes de tocar em qualquer coisa:**

> A e B conflitam. Isso quer dizer, literalmente, que **não existe uma versão do
> código com as duas** — a menos que alguém escreva uma terceira. A pergunta não
> é se ela existe. É **onde ela mora**.
>
> Se ela morar numa branch de integração, voltamos ao problema do começo: uma
> branch de longa duração com commits que não existem em lugar nenhum. E pior —
> ela apodrece, porque um push na branch de A não chega mais no ambiente.
>
> Se ela morar dentro da branch de B, B passa a carregar código de uma feature
> que talvez nunca seja mergeada, e esse código viaja até a produção.
>
> A terceira opção é a resolução não morar em branch nenhuma: virar **entrada da
> montagem**.

**Fazer** — resolver uma vez, na sua máquina:

```bash
./scripts/record-resolution.sh 1 2
# ele para aqui, com o conflito na sua frente
$EDITOR src/routes/index.ts        # mantém as duas rotas
git add src/routes/index.ts && git commit --no-edit
./scripts/publish-resolution.sh 1 2
```

**Enquanto o job roda, diga:**

> O que eu acabei de publicar não é um commit de código. É o `rr-cache` do
> `git rerere` — a memória de "quando esse conflito exato aparecer, resolva
> assim". O push nesse ref redispara a reconstrução sozinho.

**Mostrar:** `/version` de `hom` — agora **`main + a + b + c`**, `excluded`
vazio, e um campo `resolutions` apontando para o ref. A feature de B traz
`resolvedBy: ["src/routes/index.ts"]`.

**Mostrar:** `git log --oneline main..feat/b-auth-endpoint` — **um commit só**.

> Nenhuma branch foi tocada. Os dois QAs abrem a mesma URL e testam em paralelo.

**Mostrar:** o comentário novo no PR #2, e pare nesta linha:

> ### **"Essa resolução NÃO está no seu PR — e não vai para produção."**
>
> É a mesma disciplina do bloco 3, do outro lado. Lá o comentário impedia alguém
> de resolver conflito numa branch de feature. Aqui ele impede alguém de achar
> que o problema acabou. A resolução é entrada da montagem de `hom`; o merge na
> `main` continua sendo o PR revisado, e nada mais.

**Se perguntarem "e se A mudar aquele trecho?"** — é a pergunta certa, e a
resposta é a que torna isso aceitável:

> A chave da gravação é o hash do texto em conflito. Se qualquer uma das duas
> mexer ali, ela deixa de casar e B volta a ficar de fora, com o comentário de
> sempre. **Falha para o lado seguro.** Uma resolução nunca é aplicada a um
> código que ela não viu.

**Fazer, para voltar ao estado do bloco 3** (necessário para o bloco 4 seguir o
roteiro):

```bash
git push origin --delete env-resolutions
```

> E some sem deixar resíduo, igual à `priority:high`: o ambiente volta ao **mesmo
> SHA** de antes. Nem branch, nem ambiente, nem label guardam nada.

---

## 4. Push de correção em A — 3 min

> Este é o bloco que mata o cherry-pick do processo atual.

**Fazer:**

```bash
git checkout feat/a-user-endpoint
printf '\nusersRouter.get("/count", (_req, res) => res.json({ count: 2 }));\n' >> src/routes/users.ts
git commit -aqm "feat(users): endpoint de contagem"
git push -q
git checkout -q main
```

**Enquanto o job roda (~90s), diga:**

> Não toquei em label nenhuma. Não abri PR nenhum. Não fiz cherry-pick de nada.
> Um push na branch da feature, e os ambientes que contêm essa branch se
> reconstroem sozinhos.
>
> No modelo de hoje, essa correção seria: commit na branch, PR para `dev`,
> merge, cherry-pick para `hom`, merge, e depois torcer para não esquecer de
> levar o mesmo commit para a `main`. Três merges e um cherry-pick para uma
> linha de código.

**Mostrar:** `/version` de `hom` — o SHA mudou, o conjunto é o mesmo.
E `curl` no endpoint novo:

```bash
curl -s https://<projeto>-git-hom-<escopo>.vercel.app/users/count
```

**Mostrar:** o PR #2 de B **não recebeu comentário novo**. Continua em conflito,
continua em silêncio.

---

## 5. Merge de A na `main` — 4 min

**Fazer:** mergear o PR #1 pelo browser (Squash ou Merge, tanto faz).

**Enquanto os jobs rodam, diga:**

> Merge na `main` é o único gatilho de produção, e ele redispara a reconstrução
> dos dois ambientes — a base mudou.

**Mostrar:** `hom` reconstruiu. A não aparece mais como feature: ela **é** a
`main` agora. B continua fora — e **não recebeu comentário**, porque o estado
dela não mudou.

**Fazer:** disparar o `sync-prs`. Ele é **diário**, não reflexo de push — então
no palco ele é um comando, não uma surpresa:

```bash
gh workflow run sync-prs.yml
gh run watch
```

**Mostrar:** o resumo do job. Ele atualizou o PR de C — a `main` andou, a branch
acompanhou, e **ninguém rebaseou nada à mão**. E não conseguiu atualizar o de B:

> Eu disparei esse job de propósito: ele roda uma vez por dia, e não a cada
> merge. Rodar a cada push na `main` custaria uma rajada de CI proporcional ao
> número de PRs abertos, e o que ele entrega não tem essa urgência — atualizar
> uma branch **não muda se ela conflita**; o conflito é o mesmo nos dois
> sentidos do merge. Muda o tamanho do próximo merge. O ponto aqui é que
> ninguém rebaseia à mão, não que acontece no mesmo segundo.
>
> E ele não resolve conflito, nem aqui nem na montagem do ambiente: pula e
> segue. É a mesma regra nos dois lugares, e é o único ponto do processo onde
> uma pessoa precisa entrar.

**Mostrar:** o PR #2 de B. O GitHub agora diz que ele **tem conflito com a
base** — e isso, sim, bloqueia o merge. E no último run dos gates, o passo
`sincronia com a main` com o ⚠️ e a mensagem explicando o rebase.

> Repare em duas coisas separadas. Estar **atrás** da `main` não bloqueia nada
> aqui: o `strict` está desligado de propósito, e quem pega uma `main` quebrada
> é o próprio CI rodando na `main` depois do merge. O que bloqueia é o
> **conflito**, que é uma afirmação sobre o código, não sobre a data da branch.
>
> E o aviso diz para B o que fazer, com a diferença que interessa: o conflito
> de B não é mais contra a branch especulativa de alguém. É contra código real,
> revisado e mergeado. Resolver agora é resolver **uma vez**.

**Fazer — resolução à mão, no palco:**

```bash
git checkout feat/b-auth-endpoint
git fetch origin main
git rebase origin/main
```

> Conflito em `src/routes/index.ts`.

Abra o arquivo, mantenha **os dois lados** (a linha de A e a linha de B), e:

```bash
git add src/routes/index.ts
git rebase --continue
git push --force-with-lease
git checkout -q main
```

**Enquanto o job roda, diga:**

> Repare no que eu fiz e no que eu **não** fiz. Eu não resolvi conflito contra a
> branch de outra pessoa. Eu rebaseei na `main` — código que já passou por
> review e já está em produção. É a operação que qualquer um faz todo dia, e é a
> única resolução de conflito que este modelo produz.

**Mostrar:** o comentário **"✅ De volta ao ambiente `hom`"** no PR #2, e a label
`blocked:hom` removida.

**Mostrar:** `/version` de `hom` — as três rotas no ar.

---

## 6. O gate antes da `main` — 2 min

**Fazer:** abrir o PR da branch que você já empurrou no bloco 0.

```bash
gh pr create --base main --head feat/d-lint-error \
  --title "feat(health): mudanca com erro de lint" \
  --body "PR de demonstração: o gate reprova antes da main."
```

**Mostrar:** o job `gates do PR` vermelho no passo `lint`, e a `main` bloqueada.

> Isso aqui não é novidade — é CI. A novidade é **onde** ele roda. Existe um só
> PR por feature, e ele aponta para a `main`. Então os gates rodam uma vez, no
> lugar certo, antes de qualquer ambiente.
>
> Ligando ao nosso número: hoje, **10 de 10 falhas de Sonar acontecem depois do
> merge** — porque o review acontece na branch de homologação e a análise roda
> quando o código já está em `hom`. Neste modelo isso é estruturalmente
> impossível: não existe merge antes do gate, porque não existe merge em
> ambiente.

---

## 7. Fechamento — 2 min

> **Um PR por feature.** Não três. Review em um lugar só, contra a `main`.
>
> **Zero cherry-pick.** Correção é push na branch; os ambientes se reconstroem.
>
> **Reset de ambiente é a operação normal**, não um procedimento de emergência.
> `dev` e `hom` são descartáveis por construção — se estiverem estranhos, a
> resposta é reconstruir, e reconstruir é o que já acontece o tempo todo.
>
> **Conflito é informação, não bloqueio.** A branch fica de fora, o dono é
> avisado uma vez, e o ambiente continua servindo todo mundo.

E o que eu deliberadamente **não** construí:

> Sem `git rerere`, sem fila de prioridade com pesos, sem merge queue, sem
> ambiente efêmero por PR. Todas são otimizações para problemas cuja frequência
> a gente ainda não mediu. Este modelo é o mínimo que resolve o que dói hoje —
> e é ele que vai gerar o número que justifica (ou não) a próxima peça.
>
> A `priority:high` é o exemplo de como a próxima peça entra: o problema
> apareceu, e ela custou uma expressão de ordenação. Dois níveis, sem fila para
> administrar.

---

## Se der errado ao vivo

### Forçar uma reconstrução

O gatilho mais usado da demo. Actions → **rebuild-env** → **Run workflow** →
escolha o ambiente. Ou:

```bash
gh workflow run rebuild-env.yml -f environment=hom
gh run watch
```

É idempotente e stateless: pode rodar quantas vezes quiser, inclusive no meio de
outra execução.

### A Vercel está demorando

Diga, sem apressar:

> O deploy é o pedaço que eu **não** mudei nesta proposta. Ele continua sendo
> disparado por push na branch de ambiente, exatamente como hoje. O que mudou é
> quem faz o push.

E mostre a verdade pelo git, que é instantâneo e mais convincente que o browser:

```bash
git fetch origin hom && git log --oneline origin/main..origin/hom
git show origin/hom:build-manifest.json | jq
```

> O ambiente inteiro cabe em cinco linhas de log: a `main`, um merge por feature,
> e o manifesto. Nada mais existe em `hom` — é isso que "derivado" significa.

O resumo do job na aba Actions traz a mesma tabela, também sem esperar a Vercel.

### Um run aparece "cancelado"

É esperado. `cancel-in-progress: true` por ambiente: se você clicar em duas
labels rápido, a reconstrução mais nova cancela a anterior. Diga que é de
propósito — a execução mais nova monta a partir da `main` de agora, então a
anterior já nasceu obsoleta.

### O job falhou no `npm audit`

Advisory novo publicado entre o ensaio e a demo. Não tente consertar no palco:

> O gate está fazendo o trabalho dele. Um advisory foi publicado desde ontem, e
> nenhum código entra na `main` até alguém olhar.

E siga — nenhum bloco depende desse job estar verde, exceto o merge do bloco 5.
Se travar o merge, use **Merge without waiting for requirements** (você é admin).

### Um PR ficou para trás da `main`

O `sync-prs` roda uma vez por dia (06:00 UTC), então no palco ele é sempre
manual. Para forçar:

```bash
gh workflow run sync-prs.yml
gh workflow run sync-prs.yml -f dry_run=true    # só listar
```

Se ele reportar conflito, é rebase manual mesmo — o job não resolve conflito.

### Esvaziar um ambiente inteiro de uma vez

Actions → **reset-env** → **Run workflow** → escolha o ambiente. Tira
`deploy:<env>` de todos os PRs abertos de uma vez e o `rebuild-env` reconstrói
sozinho (a remoção da label pelo App emite `pull_request: unlabeled`). Ou:

```bash
gh workflow run reset-env.yml -f environment=hom
gh workflow run reset-env.yml -f environment=hom -f dry_run=true   # só listar
```

Serve para voltar ao estado do bloco 1 sem recriar PR nenhum. Não fecha PR, não
apaga branch: só devolve as vagas.

### Uma resolução gravada ficou de um ensaio anterior

Sintoma: B entra em `hom` sem você ter feito nada, e o `/version` traz um campo
`resolutions`. É o `env-resolutions` de um ensaio que não foi limpo — e note que
**fechar os PRs e recriar as branches não resolve**, porque a chave da gravação é
o conteúdo do conflito, não o PR.

```bash
git ls-remote origin refs/heads/env-resolutions   # existe?
git push origin --delete env-resolutions          # zera o remoto
rm -rf "$(git rev-parse --absolute-git-dir)/rr-cache"   # e o cache local
gh workflow run rebuild-env.yml -f environment=hom
```

O ambiente volta ao **mesmo SHA** de antes da gravação — não há resíduo em
branch, label ou manifesto. O `seed-demo.sh --reset` já faz os três passos.

### Um PR ficou com `blocked:hom` de um ensaio anterior

```bash
gh pr edit <N> --remove-label blocked:hom
gh workflow run rebuild-env.yml -f environment=hom
```

### O ambiente está com a feature "errada" dentro

Provavelmente sobrou um `priority:high` do bloco 3b. Ele inverte a ordem, então
o conjunto publicado fica diferente do que o roteiro dos blocos 4 e 5 espera:

```bash
gh pr list --label priority:high            # quem está furando a fila
gh pr edit <N> --remove-label priority:high # a remoção já dispara a reconstrução
```

Tirar a label devolve exatamente o SHA de ambiente anterior — não precisa
reconstruir na mão nem limpar mais nada.

### Recomeçar a demo do zero

```bash
./scripts/seed-demo.sh --reset
./scripts/seed-demo.sh
```

Fecha os PRs, apaga as branches de feature e os ambientes, apaga as resoluções
gravadas, e recria tudo. Leva cerca de um minuto contando a primeira
reconstrução.

> **Por que a resolução precisa ser apagada explicitamente**, se os PRs foram
> fechados e as branches recriadas: o `rr-cache` é indexado pelo **conteúdo** do
> conflito, não pelo número do PR. O seed recria as branches com exatamente as
> mesmas inserções, então o conflito reproduzido tem o **mesmo** preimage — e uma
> gravação de um ensaio anterior volta a se aplicar sozinha, nos PRs novos.
> Verificado: mesmas branches recriadas do zero, SHAs e PRs diferentes, mesma
> chave `b03c075d…`. Sem essa limpeza a demo começaria com B já dentro de `hom`
> e o bloco 3 — o conflito — simplesmente não aconteceria.

### Nada funciona e o tempo está acabando

Rode o harness offline — ele não depende de GitHub, de Vercel, nem de rede, e
demonstra o mecanismo inteiro em cinco segundos, incluindo o bloco 5:

```bash
./.github/scripts/test-assemble.sh
```
