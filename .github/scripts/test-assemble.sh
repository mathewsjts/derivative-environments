#!/usr/bin/env bash
#
# test-assemble.sh -- exercita assemble-env.sh de ponta a ponta, sem GitHub.
#
# Monta um remoto local, recria as tres branches da demo com exatamente as
# mesmas insercoes do seed e verifica os criterios de aceite que dependem da
# montagem:
#
#   1. A e B conflitam (mesmo anchor em src/routes/index.ts)
#   2. C nao conflita com ninguem (outra regiao do mesmo arquivo)
#   3. conflito de B nao impede A e C de subirem
#   4. duas execucoes seguidas produzem o MESMO SHA de ambiente
#   5. o manifesto reflete o conjunto publicado
#   6. nenhuma branch de feature carrega resolucao de conflito de outra
#   7. priority:high inverte quem ganha a vaga -- e nada mais
#   8. uma resolucao gravada poe B de volta no conjunto, sem tocar em branch
#   9. a gravacao falha para o lado seguro quando o codigo em conflito muda
#  10. quem nao usa resolucao nenhuma nao ganha campo novo no manifesto
#
# Rode antes de ensaiar a demo: ./.github/scripts/test-assemble.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1))
  else
    printf '  \033[31mFALHOU\033[0m %s\n       esperado: %s\n       obtido:   %s\n' "$1" "$3" "$2"
    FAIL=$((FAIL + 1))
  fi
}

echo "workspace: $WORK"

# --- remoto local + main ----------------------------------------------------
git init --quiet --bare "$WORK/origin.git"
git clone --quiet "$WORK/origin.git" "$WORK/repo"
cd "$WORK/repo"
git config user.name seed
git config user.email seed@example.com

# Copia a arvore atual (sem .git) para virar a main.
tar -C "$REPO_ROOT" --exclude=.git --exclude=node_modules --exclude=dist -cf - . | tar -C "$WORK/repo" -xf -
git add -A
git commit --quiet -m "main inicial"
git branch -M main
git push --quiet -u origin main

insert_before() {
  awk -v m="$1" -v l="$2" 'index($0, m) { print l } { print }' "$3" > "$3.tmp"
  mv "$3.tmp" "$3"
}

make_branch() {
  local branch="$1" route="$2" imp="$3" use="$4" imp_marker="$5" use_marker="$6"
  git checkout --quiet -B "$branch" main
  printf 'export const %sRouter = "%s";\n' "$route" "$route" > "src/routes/$route.ts"
  insert_before "$imp_marker" "$imp" src/routes/index.ts
  insert_before "$use_marker" "$use" src/routes/index.ts
  git add -A
  git commit --quiet -m "feat($route): endpoint"
  git push --quiet -u origin "$branch"
}

# A e B usam OS MESMOS marcadores. C usa os de observabilidade.
make_branch feat/a-user-endpoint users \
  "import { usersRouter } from './users';" "  app.use('/users', usersRouter);" \
  "// feature-imports:end" "// feature-routes:end"
make_branch feat/b-auth-endpoint auth \
  "import { authRouter } from './auth';" "  app.use('/auth', authRouter);" \
  "// feature-imports:end" "// feature-routes:end"
make_branch feat/c-metrics-endpoint metrics \
  "import { metricsRouter } from './metrics';" "  app.use('/metrics', metricsRouter);" \
  "// observability-imports:end" "// observability-routes:end"

git checkout --quiet main

CANDIDATES='[{"pr":1,"branch":"feat/a-user-endpoint","author":"ada"},
             {"pr":2,"branch":"feat/b-auth-endpoint","author":"grace"},
             {"pr":3,"branch":"feat/c-metrics-endpoint","author":"linus"}]'

assemble() { # assemble <arquivo-de-estado> <candidatos-json>
  ENV_NAME=hom MAX_SET=5 STATE_FILE="$1" CANDIDATES_JSON="$2" \
    bash "$REPO_ROOT/.github/scripts/assemble-env.sh" >/dev/null 2>&1
}

run_assemble() { assemble "$1" "$CANDIDATES"; }

echo
echo "== primeira montagem =="
run_assemble "$WORK/state1.json"
S1="$WORK/state1.json"

check "A e C entram no conjunto" \
  "$(jq -r '[.features[].pr] | join(",")' "$S1")" "1,3"
check "B fica de fora" \
  "$(jq -r '[.excluded[].pr] | join(",")' "$S1")" "2"
check "o motivo e conflito" \
  "$(jq -r '.excluded[0].reason' "$S1")" "conflict"
check "o conflito e atribuido ao PR #1" \
  "$(jq -r '.excluded[0].conflictsWith' "$S1")" "1"
check "o arquivo em conflito e o registry" \
  "$(jq -r '.excluded[0].files | join(",")' "$S1")" "src/routes/index.ts"

check "o build tem a rota de A" \
  "$(git show "hom:src/routes/index.ts" | grep -c "usersRouter")" "2"
check "o build tem a rota de C" \
  "$(git show "hom:src/routes/index.ts" | grep -c "metricsRouter")" "2"
check "o build NAO tem a rota de B" \
  "$(git show "hom:src/routes/index.ts" | grep -c "authRouter" || true)" "0"

check "manifesto: conjunto publicado" \
  "$(git show hom:build-manifest.json | jq -r '[.base.branch] + [.features[].branch] | join(" + ")')" \
  "main + feat/a-user-endpoint + feat/c-metrics-endpoint"
check "manifesto: ambiente" \
  "$(git show hom:build-manifest.json | jq -r '.environment')" "hom"
check "manifesto: excluidos registrados" \
  "$(git show hom:build-manifest.json | jq -r '.excluded[0].branch')" "feat/b-auth-endpoint"

HEAD1="$(jq -r '.envHead' "$S1")"

echo
echo "== segunda montagem, sem nenhuma mudanca =="
git checkout --quiet main
run_assemble "$WORK/state2.json"
HEAD2="$(jq -r '.envHead' "$WORK/state2.json")"
check "mesmo SHA de ambiente (idempotencia real)" "$HEAD2" "$HEAD1"

echo
echo "== branches de feature seguem limpas =="
check "feat/b-auth-endpoint nao tem codigo de A" \
  "$(git show "feat/b-auth-endpoint:src/routes/index.ts" | grep -c "usersRouter" || true)" "0"
check "feat/a-user-endpoint nao tem codigo de B" \
  "$(git show "feat/a-user-endpoint:src/routes/index.ts" | grep -c "authRouter" || true)" "0"
check "feat/c-metrics-endpoint nao tem codigo de A nem de B" \
  "$(git show "feat/c-metrics-endpoint:src/routes/index.ts" | grep -cE "usersRouter|authRouter" || true)" "0"

echo
echo "== B sozinha entra sem problema (o conflito e entre pares, nao com a main) =="
git checkout --quiet main
ONLY_B='[{"pr":2,"branch":"feat/b-auth-endpoint","author":"grace"}]'
ENV_NAME=hom MAX_SET=5 STATE_FILE="$WORK/state3.json" CANDIDATES_JSON="$ONLY_B" \
  bash "$REPO_ROOT/.github/scripts/assemble-env.sh" >/dev/null 2>&1
check "B entra quando A nao esta no conjunto" \
  "$(jq -r '[.features[].pr] | join(",")' "$WORK/state3.json")" "2"
check "nenhuma exclusao" \
  "$(jq -r '.excluded | length' "$WORK/state3.json")" "0"

echo
echo "== teto do conjunto =="
git checkout --quiet main
set +e
ENV_NAME=hom MAX_SET=2 STATE_FILE="$WORK/state4.json" CANDIDATES_JSON="$CANDIDATES" \
  bash "$REPO_ROOT/.github/scripts/assemble-env.sh" >/dev/null 2>&1
CAP_EXIT=$?
set -e
check "estourar o teto sai com codigo 2" "$CAP_EXIT" "2"
check "estado registra capExceeded" \
  "$(jq -r '.capExceeded' "$WORK/state4.json")" "true"

echo
echo "== atribuicao do conflito nao depende da ordem dos PRs =="
# C com numero MENOR que B: se a atribuicao fosse por "tocou o mesmo arquivo",
# C (que so mexe na regiao de observabilidade) levaria a culpa.
git checkout --quiet main
OUT_OF_ORDER='[{"pr":1,"branch":"feat/a-user-endpoint","author":"ada"},
               {"pr":2,"branch":"feat/c-metrics-endpoint","author":"linus"},
               {"pr":4,"branch":"feat/b-auth-endpoint","author":"grace"}]'
ENV_NAME=hom MAX_SET=5 STATE_FILE="$WORK/state5.json" CANDIDATES_JSON="$OUT_OF_ORDER" \
  bash "$REPO_ROOT/.github/scripts/assemble-env.sh" >/dev/null 2>&1
check "culpa ainda e do PR #1 (A), nao do #2 (C)" \
  "$(jq -r '.excluded[0].conflictsWith' "$WORK/state5.json")" "1"
check "A e C continuam publicados" \
  "$(jq -r '[.features[].pr] | join(",")' "$WORK/state5.json")" "1,2"

echo
echo "== priority:high inverte quem ganha a vaga =="
# A razao da feature existir: sem a label, B (PR maior) sempre perde para A.
# Se B for o ajuste critico, a unica saida hoje seria tirar deploy:* de A a mao.
git checkout --quiet main
B_PRIORITARIA='[{"pr":1,"branch":"feat/a-user-endpoint","author":"ada"},
                {"pr":2,"branch":"feat/b-auth-endpoint","author":"grace","priority":1},
                {"pr":3,"branch":"feat/c-metrics-endpoint","author":"linus"}]'
assemble "$WORK/prio1.json" "$B_PRIORITARIA"
check "B entra na frente, e C junto" \
  "$(jq -r '[.features[].pr] | join(",")' "$WORK/prio1.json")" "2,3"
check "agora quem fica de fora e A" \
  "$(jq -r '[.excluded[].pr] | join(",")' "$WORK/prio1.json")" "1"
check "a culpa e atribuida a B, que tomou a vaga" \
  "$(jq -r '.excluded[0].conflictsWith' "$WORK/prio1.json")" "2"
check "o build tem a rota de B" \
  "$(git show "hom:src/routes/index.ts" | grep -c "authRouter")" "2"
check "e NAO tem mais a de A" \
  "$(git show "hom:src/routes/index.ts" | grep -c "usersRouter" || true)" "0"
check "o manifesto registra a prioridade de B" \
  "$(git show hom:build-manifest.json | jq -r '.features[0].priority')" "1"

PRIO_HEAD1="$(jq -r '.envHead' "$WORK/prio1.json")"
git checkout --quiet main
assemble "$WORK/prio2.json" "$B_PRIORITARIA"
check "com prioridade a montagem segue deterministica (mesmo SHA)" \
  "$(jq -r '.envHead' "$WORK/prio2.json")" "$PRIO_HEAD1"

echo
echo "== prioridade decide a ORDEM, nao resolve conflito =="
# Com as duas marcadas, o empate cai no numero do PR -- a regra de sempre, um
# nivel acima. E a que perde continua saindo, prioritaria ou nao.
git checkout --quiet main
AMBAS_PRIORITARIAS='[{"pr":1,"branch":"feat/a-user-endpoint","author":"ada","priority":1},
                     {"pr":2,"branch":"feat/b-auth-endpoint","author":"grace","priority":1},
                     {"pr":3,"branch":"feat/c-metrics-endpoint","author":"linus"}]'
assemble "$WORK/prio3.json" "$AMBAS_PRIORITARIAS"
check "empate entre prioritarias: o PR menor fica com a vaga" \
  "$(jq -r '[.features[].pr] | join(",")' "$WORK/prio3.json")" "1,3"
check "a prioritaria que perdeu sai como qualquer outra" \
  "$(jq -r '[.excluded[].pr] | join(",")' "$WORK/prio3.json")" "2"
check "e o estado registra que ela ERA prioritaria" \
  "$(jq -r '.excluded[0].priority' "$WORK/prio3.json")" "1"

echo
echo "== quem nao usa a label nao ganha campo novo no manifesto =="
# Se `priority` aparecesse sempre, o descritor de todo ambiente ja publicado
# mudaria e o primeiro rebuild depois desta feature republicaria dev e hom sem
# nada ter mudado de verdade. A chave e omitida quando e 0 por causa disso.
check "nenhuma feature de um conjunto sem prioridade tem a chave" \
  "$(jq -r '[.features[] | has("priority")] | any' "$S1")" "false"
check "nenhum excluido tambem" \
  "$(jq -r '[.excluded[] | has("priority")] | any' "$S1")" "false"

echo
echo "== sem conflito, a label so reordena: ninguem entra nem sai =="
git checkout --quiet main
A_E_C='[{"pr":1,"branch":"feat/a-user-endpoint","author":"ada"},
        {"pr":3,"branch":"feat/c-metrics-endpoint","author":"linus"}]'
C_PRIORITARIA='[{"pr":1,"branch":"feat/a-user-endpoint","author":"ada"},
                {"pr":3,"branch":"feat/c-metrics-endpoint","author":"linus","priority":1}]'
assemble "$WORK/prio4.json" "$A_E_C"
check "ordem natural: A antes de C" \
  "$(jq -r '[.features[].pr] | join(",")' "$WORK/prio4.json")" "1,3"
git checkout --quiet main
assemble "$WORK/prio5.json" "$C_PRIORITARIA"
check "com a label, C passa na frente" \
  "$(jq -r '[.features[].pr] | join(",")' "$WORK/prio5.json")" "3,1"
check "mas nenhuma das duas sai" \
  "$(jq -r '.excluded | length' "$WORK/prio5.json")" "0"
check "e as duas rotas continuam no ar" \
  "$(git show hom:src/routes/index.ts | grep -cE "usersRouter|metricsRouter")" "4"

echo
echo "== tirar a label devolve exatamente o conjunto anterior =="
# Reversibilidade ate o SHA: e o que garante que a label nao deixa residuo.
git checkout --quiet main
assemble "$WORK/prio6.json" "$CANDIDATES"
check "sem a label, A volta e B sai de novo" \
  "$(jq -r '[.features[].pr] | join(",")' "$WORK/prio6.json")" "1,3"
check "e o SHA e o mesmo da primeira montagem do harness" \
  "$(jq -r '.envHead' "$WORK/prio6.json")" "$HEAD1"

echo
echo "== resolucao gravada: A e B no mesmo ambiente, sem tocar em branch nenhuma =="
#
# O caso que motivou a feature: dois QAs precisam testar A e B em paralelo e so
# existe um ambiente. Elas conflitam, entao nao existe uma versao do codigo com
# as duas -- a menos que alguem escreva a terceira. Esta secao prova que essa
# terceira versao pode morar FORA das branches, como entrada da montagem.
#
# A gravacao aqui e feita a mao porque o record-resolution.sh precisa do `gh`
# (ele traduz numero de PR em nome de branch). O que ele faz depois disso e
# exatamente o que esta abaixo, e a PUBLICACAO usa o script de verdade.

A_ORIGINAL="$(git rev-parse feat/a-user-endpoint)"

record_resolution() { # record_resolution -- grava a resolucao de A x B no cache local
  git config rerere.enabled true
  git config rerere.autoUpdate true
  rm -rf "$(git rev-parse --absolute-git-dir)/rr-cache"
  git checkout --quiet -B rr-work main
  git merge --no-ff --no-edit -m "merge(env): #1" feat/a-user-endpoint >/dev/null
  git merge --no-ff --no-edit -m "merge(env): #2" feat/b-auth-endpoint >/dev/null 2>&1 || true
  # A resolucao humana: mantem os dois lados. E o que qualquer um faria num
  # registry -- as duas rotas precisam existir.
  perl -0pi -e 's/^<<<<<<< .*\n//mg; s/^=======\n//mg; s/^>>>>>>> .*\n//mg' src/routes/index.ts
  git add src/routes/index.ts
  git commit --quiet --no-edit
  git checkout --quiet main
  git branch -D rr-work >/dev/null 2>&1 || true
}

record_resolution
check "a gravacao produziu uma resolucao no cache local" \
  "$(find "$(git rev-parse --absolute-git-dir)/rr-cache" -name postimage | wc -l | tr -d ' ')" "1"

# Publicacao pelo script de verdade -- inclusive o commit e o push no ref.
bash "$REPO_ROOT/scripts/publish-resolution.sh" 1 2 >/dev/null 2>&1
check "o ref env-resolutions existe no remoto" \
  "$([ -n "$(git ls-remote origin refs/heads/env-resolutions | cut -f1)" ] && echo sim || echo nao)" "sim"
check "o ref carrega meta.json com o par de PRs" \
  "$(git fetch --quiet origin env-resolutions && git show FETCH_HEAD --name-only --format= | grep -c 'meta.json')" "1"

git checkout --quiet main
run_assemble "$WORK/rr1.json"
RR1="$WORK/rr1.json"

check "agora as TRES entram no conjunto" \
  "$(jq -r '[.features[].pr] | join(",")' "$RR1")" "1,2,3"
check "nenhuma exclusao" \
  "$(jq -r '.excluded | length' "$RR1")" "0"
check "B esta marcada como resolvida" \
  "$(jq -r '.features[] | select(.pr == 2) | .resolvedBy | join(",")' "$RR1")" "src/routes/index.ts"
check "e o comentario dela sabe contra quem (o par e o PR #1)" \
  "$(jq -r '.features[] | select(.pr == 2) | .conflictsWith' "$RR1")" "1"
check "A nao ganhou marca nenhuma: quem entrou primeiro entrou limpo" \
  "$(jq -r '.features[] | select(.pr == 1) | has("resolvedBy")' "$RR1")" "false"

check "o build tem as tres rotas" \
  "$(git show hom:src/routes/index.ts | grep -cE 'usersRouter|authRouter|metricsRouter')" "6"
check "o manifesto diz de onde veio a resolucao" \
  "$(git show hom:build-manifest.json | jq -r '.resolutions.ref')" "env-resolutions"
check "e o manifesto marca a feature que dependeu dela" \
  "$(git show hom:build-manifest.json | jq -r '[.features[] | select(has("resolvedBy")) | .pr] | join(",")')" "2"

echo
echo "== e as branches continuam limpas: a resolucao nao mora em nenhuma delas =="
# O ponto inteiro da feature. Se isto falhar, ela virou branch de integracao.
check "feat/a-user-endpoint segue sem codigo de B" \
  "$(git show feat/a-user-endpoint:src/routes/index.ts | grep -c authRouter || true)" "0"
check "feat/b-auth-endpoint segue sem codigo de A" \
  "$(git show feat/b-auth-endpoint:src/routes/index.ts | grep -c usersRouter || true)" "0"
check "as branches nao se moveram" \
  "$(git rev-parse feat/a-user-endpoint)" "$A_ORIGINAL"

echo
echo "== com resolucao, a montagem segue deterministica =="
RRHEAD1="$(jq -r '.envHead' "$RR1")"
git checkout --quiet main
run_assemble "$WORK/rr2.json"
check "mesmo SHA de ambiente" "$(jq -r '.envHead' "$WORK/rr2.json")" "$RRHEAD1"

# O no-op compara CONJUNTOS lendo o manifesto da branch remota, entao ele so
# tem o que comparar depois de uma publicacao de verdade. E vale testar aqui:
# se `resolutions` entrasse no descritor de forma instavel, republicar o mesmo
# conjunto viraria churn eterno.
git push --quiet origin "HEAD:refs/heads/hom"
git checkout --quiet main
run_assemble "$WORK/rr2b.json"
check "republicar o mesmo conjunto com resolucao continua sendo no-op" \
  "$(jq -r '.noop' "$WORK/rr2b.json")" "true"
git push --quiet origin --delete hom

echo
echo "== a gravacao independe da ordem: priority:high nao a invalida =="
#
# O id de um conflito no rerere e o hash do preimage NORMALIZADO -- os dois lados
# sao ordenados antes do hash e o nome da branch nao entra. Entao a gravacao
# feita com A antes de B tambem vale com B antes de A. Sem esta propriedade,
# priority:high e resolucao gravada seriam mutuamente exclusivas.
git checkout --quiet main
assemble "$WORK/rr3.json" "$B_PRIORITARIA"
check "B entra na frente e A NAO sai mais" \
  "$(jq -r '[.features[].pr] | join(",")' "$WORK/rr3.json")" "2,1,3"
check "nenhuma exclusao, mesmo com a ordem invertida" \
  "$(jq -r '.excluded | length' "$WORK/rr3.json")" "0"
check "agora quem entra por resolucao e A, que chegou depois" \
  "$(jq -r '[.features[] | select(has("resolvedBy")) | .pr] | join(",")' "$WORK/rr3.json")" "1"
check "e o conteudo e o mesmo: as tres rotas no ar" \
  "$(git show hom:src/routes/index.ts | grep -cE 'usersRouter|authRouter|metricsRouter')" "6"

echo
echo "== quem nao depende de resolucao nao ganha campo novo =="
#
# O ref existe e tem uma gravacao dentro, mas este conjunto (A e C) nao conflita.
# Se `resolutions` aparecesse assim mesmo, o descritor de TODO ambiente mudaria
# e o primeiro rebuild depois desta feature republicaria dev e hom sem nada ter
# mudado de verdade -- exatamente o que a omissao de `priority` evita.
git checkout --quiet main
assemble "$WORK/rr4.json" "$A_E_C"
check "conjunto sem conflito nao registra resolutions" \
  "$(jq -r '.resolutions' "$WORK/rr4.json")" "null"
check "e nenhuma feature ganha resolvedBy" \
  "$(jq -r '[.features[] | has("resolvedBy")] | any' "$WORK/rr4.json")" "false"
check "o SHA e identico ao do mesmo conjunto antes de existir resolucao alguma" \
  "$(jq -r '.envHead' "$WORK/rr4.json")" "$(jq -r '.envHead' "$WORK/prio4.json")"

echo
echo "== falha para o lado seguro: A mexe na regiao e a gravacao para de valer =="
#
# A propriedade que torna isto aceitavel. Uma resolucao gravada NUNCA sobrevive
# a uma mudanca real no codigo que ela reconciliava: o id e o hash do preimage.
# O sistema degrada para o comportamento de sempre -- exclusao com comentario --
# e nao para um merge silencioso de codigo que ninguem revisou.
git checkout --quiet -B feat/a-user-endpoint feat/a-user-endpoint
insert_before "// feature-imports:end" "import { profileRouter } from './profile';" src/routes/index.ts
printf "import { Router } from 'express';\nexport const profileRouter = Router();\n" > src/routes/profile.ts
git add -A
git commit --quiet -m "feat(users): + /profile na mesma regiao"
git push --quiet origin feat/a-user-endpoint

git checkout --quiet main
run_assemble "$WORK/rr5.json"
check "B volta a ficar de fora" \
  "$(jq -r '[.excluded[].pr] | join(",")' "$WORK/rr5.json")" "2"
check "com a atribuicao de culpa correta, e nao 'atrasada em relacao a main'" \
  "$(jq -r '.excluded[0].conflictsWith' "$WORK/rr5.json")" "1"
check "e A e C seguem publicadas" \
  "$(jq -r '[.features[].pr] | join(",")' "$WORK/rr5.json")" "1,3"

# Devolve A ao estado anterior para as secoes seguintes.
git checkout --quiet -B feat/a-user-endpoint "$A_ORIGINAL"
git push --quiet --force origin feat/a-user-endpoint
git checkout --quiet main

echo
echo "== o comentario do PR: a maquina de estados do notify.sh =="
#
# O comentario e o produto, nao um efeito colateral: se ele disser "o conflito
# nao existe mais" para quem entrou por resolucao, a pessoa acredita que a
# branch dela esta limpa e nao rebaseia nunca. Aqui a maquina roda inteira sem
# GitHub, pelos ganchos BLOCKED_JSON e COMMENT_STATE_JSON.
git checkout --quiet main
run_assemble "$WORK/rrN.json"

notify() { # notify <blocked-json> <estados-ja-comentados>
  ENV_NAME=hom STATE_FILE="$WORK/rrN.json" DRY_RUN=true GH_REPO=teste/teste \
  BLOCKED_JSON="$1" COMMENT_STATE_JSON="$2" \
    bash "$REPO_ROOT/.github/scripts/notify.sh" 2>&1
}

# B estava excluida (carrega blocked:hom, ultimo comentario foi de conflito) e
# agora entra por resolucao: transicao conflict -> resolved.
OUT="$(notify '[2]' '{"2":"conflict"}')"
check "comenta a entrada por resolucao" \
  "$(grep -c 'Dentro de .*hom.*por uma resolução gravada' <<<"$OUT")" "1"
check "e nomeia o par contra quem ela conflita" \
  "$(grep -c 'conflita com #1' <<<"$OUT")" "1"
check "diz explicitamente que a resolucao nao esta no PR" \
  "$(grep -c 'NÃO está no seu PR' <<<"$OUT")" "1"
check "NAO diz que o conflito acabou (seria mentira)" \
  "$(grep -c 'conflito que a excluía não existe mais' <<<"$OUT" || true)" "0"
check "e devolve a marca blocked:hom, porque ela esta DENTRO agora" \
  "$(grep -c '\[dry-run\] -blocked:hom em #2' <<<"$OUT")" "1"
check "A e C, que entraram limpas e nunca sairam, nao geram comentario" \
  "$(grep -c 'comentario para #1\|comentario para #3' <<<"$OUT" || true)" "0"

# Segunda execucao, mesmo estado: silencio absoluto.
OUT2="$(notify '[]' '{"2":"resolved"}')"
check "segue entrando por resolucao -> nenhum comentario" \
  "$(grep -c 'comentario para #' <<<"$OUT2" || true)" "0"
check "e o log diz por que ficou calado" \
  "$(grep -c '#2 segue entrando por resolucao' <<<"$OUT2")" "1"

# A resolucao deixou de ser necessaria (o outro PR mergeou): resolved -> limpa.
# Simulado trocando o state file por um em que ninguem tem resolvedBy, mas o
# manifesto anterior dizia que #2 dependia de uma.
jq '(.features[] |= del(.resolvedBy, .conflictsWith)) | .resolutions = null | .resolvedBefore = [2]' \
  "$WORK/rrN.json" > "$WORK/rrN-limpo.json"
OUT3="$(ENV_NAME=hom STATE_FILE="$WORK/rrN-limpo.json" DRY_RUN=true GH_REPO=teste/teste \
        BLOCKED_JSON='[]' COMMENT_STATE_JSON='{"2":"resolved"}' \
        bash "$REPO_ROOT/.github/scripts/notify.sh" 2>&1)"
check "avisa que a resolucao nao e mais necessaria" \
  "$(grep -c 'não precisa mais da resolução gravada' <<<"$OUT3")" "1"
check "e sugere o rebase, que agora e contra codigo mergeado" \
  "$(grep -c 'vale rebasear' <<<"$OUT3")" "1"

echo
echo "== apagar o ref devolve exatamente o conjunto anterior =="
# Reversibilidade ate o SHA, como na priority:high: a resolucao nao deixa
# residuo em lugar nenhum -- nem em branch, nem no ambiente.
git push --quiet origin --delete env-resolutions
git checkout --quiet main
run_assemble "$WORK/rr6.json"
check "sem o ref, B fica de fora de novo" \
  "$(jq -r '[.excluded[].pr] | join(",")' "$WORK/rr6.json")" "2"
check "e o SHA volta a ser o da primeira montagem do harness" \
  "$(jq -r '.envHead' "$WORK/rr6.json")" "$HEAD1"

echo
echo "== bloco 5 da demo: A e mergeada na main ==
"
git checkout --quiet main
git merge --quiet --no-ff -m "merge: #1 feat/a-user-endpoint" feat/a-user-endpoint
git push --quiet origin main

AFTER_MERGE='[{"pr":2,"branch":"feat/b-auth-endpoint","author":"grace"},
              {"pr":3,"branch":"feat/c-metrics-endpoint","author":"linus"}]'
ENV_NAME=hom MAX_SET=5 STATE_FILE="$WORK/state6.json" CANDIDATES_JSON="$AFTER_MERGE" \
  bash "$REPO_ROOT/.github/scripts/assemble-env.sh" >/dev/null 2>&1
check "B ainda fica de fora depois do merge de A" \
  "$(jq -r '[.excluded[].pr] | join(",")' "$WORK/state6.json")" "2"
check "agora o conflito e com a propria main, sem culpar outro PR" \
  "$(jq -r '.excluded[0].conflictsWith' "$WORK/state6.json")" "null"
check "C segue publicada" \
  "$(jq -r '[.features[].pr] | join(",")' "$WORK/state6.json")" "3"

echo
echo "== B rebaseia na main e resolve o conflito UMA vez =="
# E o que o apresentador faz a mao no palco: rebase na main e resolver mantendo
# os dois lados. Aqui a resolucao e automatizada so para poder ser verificada.
git checkout --quiet feat/b-auth-endpoint
git fetch --quiet origin main
set +e
git rebase origin/main >/dev/null 2>&1
REBASE_CONFLICT=$?
set -e
check "o rebase conflita (e esse conflito e contra codigo ja mergeado)" \
  "$([ "$REBASE_CONFLICT" -ne 0 ] && echo sim || echo nao)" "sim"

perl -0pi -e 's/^<<<<<<< .*\n//mg; s/^=======\n//mg; s/^>>>>>>> .*\n//mg' src/routes/index.ts
git add src/routes/index.ts
GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
git push --quiet --force-with-lease origin feat/b-auth-endpoint

check "a branch de B agora contem o codigo de A porque A ESTA NA MAIN" \
  "$(git show "feat/b-auth-endpoint:src/routes/index.ts" | grep -c "usersRouter")" "2"

git checkout --quiet main
ENV_NAME=hom MAX_SET=5 STATE_FILE="$WORK/state7.json" CANDIDATES_JSON="$AFTER_MERGE" \
  bash "$REPO_ROOT/.github/scripts/assemble-env.sh" >/dev/null 2>&1
check "B volta ao conjunto" \
  "$(jq -r '[.features[].pr] | join(",")' "$WORK/state7.json")" "2,3"
check "nenhuma exclusao sobrou" \
  "$(jq -r '.excluded | length' "$WORK/state7.json")" "0"
check "as tres rotas estao no ar" \
  "$(git show hom:src/routes/index.ts | grep -cE "usersRouter|authRouter|metricsRouter")" "6"

echo
echo "== ciclo de estados: voltar a um conjunto ja publicado gera SHA inedito =="
#
# Regressao do bug que congelou a URL de dev na demo: a montagem e
# deterministica, entao republicar um conjunto anterior reproduzia o commit byte
# a byte. A Vercel deduplica deploy por SHA, ignorava o push e nao movia o alias
# da branch -- a branch andava, a URL ficava parada, sem erro nenhum.
#
# Este bloco PUBLICA de verdade (push no remoto local), que e o que faltava para
# o bug aparecer no harness.
publish() {
  local state="$1" cands="$2"
  ENV_NAME=hom MAX_SET=5 STATE_FILE="$state" CANDIDATES_JSON="$cands" \
    bash "$REPO_ROOT/.github/scripts/assemble-env.sh" >/dev/null 2>&1
  if [ "$(jq -r '.noop' "$state")" = "true" ]; then return 0; fi
  local lease
  lease="$(jq -r '.remoteHead // ""' "$state")"
  if [ -z "$lease" ]; then
    git push --quiet origin "HEAD:refs/heads/hom"
  else
    git push --quiet --force-with-lease="refs/heads/hom:$lease" origin "HEAD:refs/heads/hom"
  fi
}

ONLY_B_SET='[{"pr":2,"branch":"feat/b-auth-endpoint","author":"grace"}]'
B_AND_C_SET='[{"pr":2,"branch":"feat/b-auth-endpoint","author":"grace"},
               {"pr":3,"branch":"feat/c-metrics-endpoint","author":"linus"}]'

git checkout --quiet main
publish "$WORK/cycle1.json" "$ONLY_B_SET"
CYCLE1="$(jq -r '.envHead' "$WORK/cycle1.json")"
check "primeira publicacao registra previousEnvHead nulo" \
  "$(git show hom:build-manifest.json | jq -r '.previousEnvHead')" "null"

git checkout --quiet main
publish "$WORK/cycle2.json" "$ONLY_B_SET"
check "mesmo conjunto de novo: no-op" \
  "$(jq -r '.noop' "$WORK/cycle2.json")" "true"
check "no-op nao mexe no SHA publicado" \
  "$(jq -r '.envHead' "$WORK/cycle2.json")" "$CYCLE1"
check "o remoto continua exatamente onde estava" \
  "$(git ls-remote origin refs/heads/hom | cut -f1)" "$CYCLE1"

git checkout --quiet main
publish "$WORK/cycle3.json" "$B_AND_C_SET"
CYCLE3="$(jq -r '.envHead' "$WORK/cycle3.json")"
check "conjunto diferente publica" \
  "$([ "$CYCLE3" != "$CYCLE1" ] && echo sim || echo nao)" "sim"
check "previousEnvHead aponta para a publicacao anterior" \
  "$(git show hom:build-manifest.json | jq -r '.previousEnvHead')" "$CYCLE1"

git checkout --quiet main
publish "$WORK/cycle4.json" "$ONLY_B_SET"
CYCLE4="$(jq -r '.envHead' "$WORK/cycle4.json")"
check "voltar ao conjunto inicial NAO e no-op" \
  "$(jq -r '.noop' "$WORK/cycle4.json")" "false"
check "e produz SHA diferente do da primeira vez (o bug)" \
  "$([ "$CYCLE4" != "$CYCLE1" ] && echo sim || echo nao)" "sim"
check "o conjunto publicado e o mesmo de antes, ainda assim" \
  "$(git show hom:build-manifest.json | jq -r '[.base.branch] + [.features[].branch] | join(" + ")')" \
  "main + feat/b-auth-endpoint"
check "a historia de merges e identica (so o commit de manifesto muda)" \
  "$(git rev-parse "${CYCLE4}~1")" "$(git rev-parse "${CYCLE1}~1")"

echo
printf '\033[1m%s ok, %s falha(s)\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
