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
  pr-gates.yml              typecheck, lint, testes, audit, docker, Sonar, sincronia
  rebuild-env.yml           o job que deriva dev e hom da main
  label-ttl.yml             devolve a vaga de PR parado
  fake-deploy.yml           prova que o push do App dispara workflows

.github/scripts/
  assemble-env.sh           monta o conjunto (não publica — roda no laptop)
  notify.sh                 comenta só em transição de estado
  test-assemble.sh          29 verificações de ponta a ponta, offline

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
maior committer date entre a `main` e as features do conjunto), então o mesmo
conjunto sempre produz o mesmo SHA — e o job detecta isso e não publica.

**A atribuição do conflito é por reprodução, não por heurística.** Saber que
duas branches "tocaram o mesmo arquivo" não diz qual delas é o par do conflito.
O job reproduz em pares (`main + X`, depois `main + F + X` para cada F já no
conjunto) e reporta o primeiro que conflita. É barato e acerta o PR certo — que
importa, porque o comentário manda a pessoa esperar um PR específico.

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
