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

run_assemble() {
  ENV_NAME=hom MAX_SET=5 STATE_FILE="$1" CANDIDATES_JSON="$CANDIDATES" \
    bash "$REPO_ROOT/.github/scripts/assemble-env.sh" >/dev/null 2>&1
}

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
echo "== bloco 5 da demo: A e mergeada na main =="
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
