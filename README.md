# derivative-environments

POC de um modelo de branching em que **`dev` e `hom` deixam de ser branches que
recebem merge e viram artefatos derivados**, reconstruídos por um job a partir
da `main` mais os PRs marcados por label.

- **Como apresentar:** [DEMO.md](DEMO.md) — roteiro de 20 minutos
- **O que configurar à mão:** [SETUP.md](SETUP.md) — GitHub App, labels,
  rulesets, SonarCloud, Vercel

---

## O problema

Três branches de longa duração, uma por ambiente. Merge em cada uma dispara o
deploy daquele ambiente. Consequências:

- cada feature vira até **3 PRs**;
- o review acontece na branch de **homologação**, não contra a `main`;
- ajuste em uma feature exige **cherry-pick** entre ambientes;
- as branches de ambiente **acumulam commits que não existem em outro lugar** —
  resoluções de conflito, correções aplicadas direto, merges parciais.

## A proposta

```
main ──────────────────────────────────────────►  produção
  │
  ├── feat/a  ──┐  (PR #1, label deploy:hom)
  ├── feat/b  ──┤  (PR #2, conflita com A)
  └── feat/c  ──┘  (PR #3, label deploy:hom)
                │
                ▼
        rebuild-env  ──►  hom = reset(main) + merge(A) + merge(C)
                              B fica de fora, com um comentário no PR dela
```

- **Um PR por feature**, sempre `feat/X → main`. Review, gates e ajustes só ali.
- **`dev` e `hom` não recebem merge humano.** São reconstruídas do zero:
  `reset` na `main` + reaplicação das branches marcadas + `push --force-with-lease`.
- **Deploy continua sendo push na branch de ambiente.** Muda quem empurra: o job.
- **Conflito não trava o ambiente.** A branch conflitante fica de fora, o resto
  sobe, e o PR dela recebe um comentário — uma vez só.
- **Merge na `main` é o único gatilho de produção**, com CI verde e approve.

## Como o modelo funciona na prática

| Você quer | Você faz | O modelo faz |
|---|---|---|
| subir uma feature para `hom` | aplica a label `deploy:hom` no PR | reconstrói `hom` com ela dentro |
| corrigir algo já em `hom` | `git push` na branch da feature | reconstrói `hom`, sem re-labelar nada |
| tirar uma feature de `hom` | remove a label | reconstrói `hom` sem ela |
| ir para produção | merge do PR na `main` | reconstrói os dois ambientes sobre a nova base |
| resolver um conflito | rebase na `main`, **uma vez** | a branch volta ao conjunto sozinha |

## O que tem aqui

```
src/routes/index.ts         registry central — é aqui que as features conflitam
src/routes/version.ts       GET /version: o conjunto que está no ar
build-manifest.json         escrito pelo job; a fonte de verdade do /version

.github/workflows/
  pr-gates.yml              typecheck, lint, testes, audit, docker, Sonar — no PR e na main
  rebuild-env.yml           o job que deriva dev e hom da main
  sync-prs.yml              atualiza os PRs marcados com a main, uma vez por dia
  label-ttl.yml             devolve a vaga de PR parado
  reset-env.yml             esvazia um ambiente (manual) tirando todas as labels
  fake-deploy.yml           prova que o push do App dispara workflows

.github/scripts/
  assemble-env.sh           monta o conjunto (não publica — roda no laptop)
  notify.sh                 comenta só em transição de estado
  test-assemble.sh          a montagem, de ponta a ponta, offline
  test-workflows.sh         invariantes de concorrência dos workflows

scripts/
  seed-demo.sh              cria o estado inicial da demo (idempotente)
  create-labels.sh          cria as 4 labels
```

## Decisões que valem explicar

**O conflito é determinístico de propósito.** `src/routes/index.ts` tem blocos
delimitados por marcadores. A e B inserem no **mesmo anchor** — conflitam
sempre. C insere num bloco separado, longe o bastante para o git tratar como
outro hunk — não conflita com ninguém. Mesmo arquivo, resultados diferentes: a
exclusão é por **região**, não por arquivo.

**O manifesto é commitado, não injetado.** A Vercel builda a partir do conteúdo
do commit que recebeu; o job não tem como injetar variável de ambiente nesse
build. Então ele escreve `build-manifest.json` como último commit da branch de
ambiente. Efeito colateral bom: `git log --oneline main..hom` descreve o
ambiente inteiro.

**As datas dos commits são pinadas.** Data de autor e de committer entram no
hash do merge commit — sem fixá-las, duas execuções idênticas produziriam SHAs
diferentes e a Vercel redeployaria à toa. A data é função pura das entradas (o
maior committer date entre a `main` e as features do conjunto), então a mesma
história de merges sempre produz os mesmos commits.

**E o manifesto registra `previousEnvHead`.** O determinismo acima tem uma
armadilha: *voltar* a um conjunto já publicado reproduz o commit byte a byte, e
um provedor que deduplica deploy por SHA — a Vercel faz — ignora esse push sem
mover o alias da branch. A branch anda, a URL fica parada num conjunto antigo, e
não há erro em lugar nenhum. Gravar o SHA que o ambiente substituiu torna cada
transição única. O teste de "nada mudou" passou a comparar o **conjunto**
publicado (base, features, excluded), não o SHA — então rodar duas vezes sem
mudança continua sendo no-op de verdade.

**A atribuição do conflito é por reprodução, não por heurística.** Saber que
duas branches "tocaram o mesmo arquivo" não diz qual delas é o par do conflito.
O job reproduz em pares (`main + X`, depois `main + F + X` para cada F já no
conjunto) e reporta o primeiro que conflita. É barato e acerta o PR certo — que
importa, porque o comentário manda a pessoa esperar um PR específico.

**A lógica de derivação vem da `main`, não do ref que disparou o job** — em duas
camadas, porque o GitHub tem dois lugares onde a procedência escorrega:

- O `rebuild-env` usa `pull_request_target`, não `pull_request`. Com
  `pull_request`, o GitHub executa a **definição do workflow que veio na branch
  da feature**; com `pull_request_target`, a da branch base.
- Depois do checkout, o job carrega `assemble-env.sh` e `notify.sh` de
  `origin/main` — porque em evento de `push` numa branch de feature o checkout
  é a própria branch.

Sem as duas, "derivado da `main`" é meia verdade: uma branch atrasada monta o
ambiente com a lógica dela, e um PR não revisado poderia mudar como *todos* os
ambientes são montados. O limite de confiança do modelo é a label `deploy:<env>`,
que só quem tem permissão de escrita aplica.

**O ambiente anterior não entra no build.** O job lê exatamente duas coisas da
branch de ambiente: o SHA (para o `--force-with-lease`) e o manifesto (para
responder "o conjunto mudou?"). Nenhum byte do conteúdo anterior sobrevive — a
montagem parte sempre de `origin/main`.

**A `main` tem CI, e é por isso que o `strict` está desligado.** Até aqui nenhum
workflow rodava num push para a `main` — `pr-gates.yml` só tinha
`on: pull_request` — e a `main` é produção. O único sinal pós-merge era o
`docker build` do `rebuild-env`, que apenas compila. Agora os dois jobs rodam
também no push: dois por merge, sempre os mesmos dois. É uma troca deliberada de
**prevenção O(N × PRs abertos)** — o `strict` do ruleset, que invalida todos os
PRs abertos a cada merge — por **detecção O(1)**: a `main` quebrada aparece em
~60 segundos. O que se perde é a janela em que um PR mergeia validado contra uma
`main` anterior, e o preço dela é um PR de correção, não uma produção quebrada
em silêncio. O custo escrito está em [SETUP.md](SETUP.md) §3b.

**Estar atrasada não exclui uma branch do ambiente — e atualizá-la não muda se
ela conflita.** A montagem sempre parte de `origin/main` e faz merge da branch:
uma branch atrás da `main` entra normalmente enquanto não conflitar. E o
`sync-prs` faz `merge main → branch` enquanto o `assemble-env.sh` faz
`merge branch → main`: mesma base de merge, mesmos dois commits, **mesmo
conflito**. Atualizar não muda se conflita hoje; muda o *tamanho* do próximo
merge e a hora em que a pessoa descobre que vai precisar rebasear. Com o
`strict` desligado (SETUP.md §3b), é isso que sobrou do `sync-prs` — "integre
cedo, em pedaços pequenos", benefício real e sem urgência — e é por isso que ele
roda **uma vez por dia**, e não a cada push na `main`. Ele atualiza com o
*Update branch* nativo (merge, sem force-push) e, em conflito, **pula e segue** —
resolver conflito contra a `main` é trabalho humano, feito uma vez, no PR.

**E ele só atualiza os PRs marcados com `deploy:*`.** Atualizar todo PR aberto
transforma uma execução numa rajada: cada atualização é um push, e cada push
dispara os gates e uma reconstrução. Com 30 PRs abertos, são ~30 runs extras — a
amplificação cresce com o número de PRs abertos, não com o tamanho do time, e é
a mais perigosa deste desenho em escala real. Enquanto ele era reflexo de push
na `main`, esse número se pagava a cada merge; diário e só nos marcados, ele é
O(1/dia). Para quem não está em ambiente nenhum, estar atrasado é inofensivo,
justamente porque a montagem parte da `main`. Um PR sem label que ganhar uma
depois é atualizado no próximo disparo — ou na hora, pelo *Update branch* do
próprio PR. Para o comportamento antigo, o workflow aceita `only_labeled`
desmarcado no disparo manual.

**Quem decide se há trabalho fica fora da fila de concorrência.** O
`rebuild-env` usa `cancel-in-progress` por ambiente — uma reconstrução parte
sempre da `main` de agora, então a execução mais nova torna a anterior
irrelevante. Isso só é verdade entre execuções que vão *de fato* reconstruir.
Enquanto a decisão morava dentro do job, um evento irrelevante reivindicava o
grupo, cancelava quem estava trabalhando e só então descobria que não tinha nada
a fazer — e os ambientes ficavam parados numa base antiga, com todos os
workflows verdes. A decisão virou um job próprio, sem grupo, que emite a matriz
do job seguinte: lista vazia, nenhum job.

**A notificação usa label como estado.** `blocked:<env>` é a única memória do
sistema. Sem ela, um job que roda a cada push transformaria um conflito de meio
dia em quarenta comentários.

## O que este modelo NÃO tem, de propósito

Sem `git rerere`, sem fila de prioridade entre branches, sem merge queue, sem
ambiente efêmero por PR. São otimizações para problemas cuja frequência ainda
não foi medida. Este é o mínimo que resolve o que dói hoje — e é ele que produz
o dado para justificar (ou descartar) a próxima peça.

## Rodando local

```bash
npm ci
npm run dev            # http://localhost:3000/version
npm test
npm run lint
docker build -t derivative-environments .

./.github/scripts/test-assemble.sh   # o mecanismo inteiro, sem GitHub
```
