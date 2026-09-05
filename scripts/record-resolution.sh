#!/usr/bin/env bash
#
# record-resolution.sh <prA> <prB> -- grava a resolucao do conflito entre dois PRs.
#
# POR QUE EXISTE
#
# Duas branches que conflitam nao podem coexistir num ambiente: nao existe uma
# versao do codigo que contenha as duas, a menos que alguem escreva a terceira.
# A pergunta que importa nao e SE ela existe -- e onde ela mora.
#
#   numa branch de integracao  -> branch de longa duracao com commits que nao
#                                 existem em outro lugar. E o que este modelo
#                                 eliminou, e ela apodrece: push na feature nao
#                                 chega mais no ambiente.
#   dentro de uma das features -> a branch passa a carregar codigo de uma
#                                 feature que talvez nunca seja mergeada, e ele
#                                 viaja junto ate a producao.
#   AQUI                       -> a resolucao vira ENTRADA da derivacao.
#
# Este script produz exatamente um artefato: o rr-cache do git rerere. Nenhuma
# branch de feature e tocada. A branch de trabalho e descartavel.
#
#   ./scripts/record-resolution.sh 1 2      prepara o merge e para para voce resolver
#   ./scripts/record-resolution.sh 1 2 --redo   ignora a gravacao que ja existe
#
# Depois de resolver e commitar:
#   ./scripts/publish-resolution.sh 1 2
set -euo pipefail

PR_A="${1:?uso: record-resolution.sh <prA> <prB> [--redo]}"
PR_B="${2:?uso: record-resolution.sh <prA> <prB> [--redo]}"
REDO=false
[ "${3:-}" = "--redo" ] && REDO=true

RESOLUTIONS_REF="${RESOLUTIONS_REF:-env-resolutions}"

# Caminho ABSOLUTO do script irmao. A branch de trabalho sai de origin/main, e
# se estes scripts ainda nao estiverem na main (o PR que os traz aberto, por
# exemplo), um `./scripts/publish-resolution.sh` relativo nao existe la.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# Absoluto de proposito: --git-path devolve caminho RELATIVO, e o
# publish-resolution.sh faz cd para um tmpdir depois de calcular isto.
RR_CACHE="$(git rev-parse --absolute-git-dir)/rr-cache"

log()     { printf '  %s\n' "$*"; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

git diff --quiet && git diff --cached --quiet \
  || { echo "Worktree suja. Commite ou guarde antes." >&2; exit 1; }

BR_A="$(gh pr view "$PR_A" --json headRefName --jq .headRefName)"
BR_B="$(gh pr view "$PR_B" --json headRefName --jq .headRefName)"

section "Preparando"
git fetch --quiet origin main "$BR_A" "$BR_B"
log "#$PR_A = $BR_A"
log "#$PR_B = $BR_B"

# A ORDEM IMPORTA MENOS DO QUE PARECE. O id de um conflito no rerere e o hash do
# preimage NORMALIZADO -- os dois lados sao ordenados antes do hash, e o nome da
# branch nao entra. Entao a gravacao feita com A antes de B tambem se aplica com
# B antes de A, que e o que priority:high faz. Verificado no test-assemble.sh.
section "Cache de resolucoes"
if [ "$REDO" = true ]; then
  rm -rf "$RR_CACHE"
  log "--redo: cache local zerado, a gravacao existente sera ignorada"
elif git fetch --quiet origin "+refs/heads/$RESOLUTIONS_REF:refs/remotes/origin/$RESOLUTIONS_REF" 2>/dev/null; then
  rm -rf "$RR_CACHE"; mkdir -p "$RR_CACHE"
  git archive "origin/$RESOLUTIONS_REF" rr-cache 2>/dev/null \
    | tar -x -C "$(git rev-parse --absolute-git-dir)" 2>/dev/null || true
  log "$(find "$RR_CACHE" -name postimage 2>/dev/null | wc -l | tr -d ' ') gravacao(oes) ja publicada(s)"
else
  log "ref $RESOLUTIONS_REF ainda nao existe -- esta sera a primeira"
fi

git config rerere.enabled true
git config rerere.autoUpdate true

section "Merge"
WORK_BRANCH="rr/$PR_A-$PR_B"
git checkout --quiet -B "$WORK_BRANCH" origin/main
git merge --no-ff --no-edit -m "merge(env): #$PR_A $BR_A" "origin/$BR_A" >/dev/null
log "#$PR_A entrou"

if git merge --no-ff --no-edit -m "merge(env): #$PR_B $BR_B" "origin/$BR_B" >/dev/null 2>&1; then
  section "Nada a gravar"
  echo "  #$PR_A e #$PR_B nao conflitam. As duas ja entram no mesmo ambiente."
  git checkout --quiet - >/dev/null 2>&1 || git checkout --quiet main
  git branch -D "$WORK_BRANCH" >/dev/null 2>&1 || true
  exit 0
fi

# Com uma gravacao aplicavel o merge AINDA sai com 1, mas com o indice limpo.
if [ -z "$(git diff --name-only --diff-filter=U)" ]; then
  section "Ja estava gravado"
  git commit --quiet --no-edit
  echo "  A resolucao deste conflito ja existe em $RESOLUTIONS_REF e foi aplicada."
  echo "  Para gravar OUTRA no lugar dela:"
  echo "    $SELF_DIR/record-resolution.sh $PR_A $PR_B --redo"
  echo
  echo "  Limpando a branch de trabalho."
  git checkout --quiet main
  git branch -D "$WORK_BRANCH" >/dev/null 2>&1 || true
  exit 0
fi

section "Resolva"
git diff --name-only --diff-filter=U | sed 's/^/  /'
cat <<EOF

  Voce esta em $WORK_BRANCH. Resolva os arquivos acima como resolveria em
  qualquer lugar, e entao:

    git add <arquivos> && git commit --no-edit
    $SELF_DIR/publish-resolution.sh $PR_A $PR_B

  A branch $WORK_BRANCH e lixo: o publish nao a usa, e nada dela chega em
  branch de feature nenhuma. O unico artefato e o rr-cache.

  Para conferir o que sera gravado antes de commitar:  git rerere diff
EOF
