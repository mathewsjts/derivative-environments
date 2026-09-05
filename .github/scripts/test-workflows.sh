#!/usr/bin/env bash
#
# test-workflows.sh -- invariantes de concorrencia dos workflows, offline.
#
# POR QUE EXISTE
#
# O mesmo bug ja apareceu duas vezes, com causas diferentes e o mesmo sintoma:
# um ambiente publicado numa base ou num conjunto antigo, com TODOS os workflows
# verdes. Nao ha job vermelho, nao ha log de erro. A unica forma de perceber e
# olhar o ambiente.
#
#   PR #10  A decisao de reconstruir morava dentro do job com grupo. Um evento
#           irrelevante reivindicava o grupo, cancelava quem trabalhava, e so
#           entao descobria que nao tinha o que fazer.
#   PR #11  O job virou um so para os dois ambientes, com grupo unico, enquanto
#           o guard passou a escolher UM ambiente. Runs de dev e de hom caiam no
#           mesmo grupo, um cancelava o outro, e ninguem refazia o cancelado.
#
# Os dois violam a mesma regra: o grupo de concorrencia tem que ser o RECURSO
# protegido, e so quem vai mexer nele entra na fila. Este script transforma essa
# regra em teste, porque comentario nao reprova PR.
#
#   ./.github/scripts/test-workflows.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
WF=.github/workflows/rebuild-env.yml

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

# O bloco de um job = da linha "  <id>:" ate a proxima linha "  <id>:".
job_block() {
  awk -v alvo="  $1:" '
    $0 == alvo { dentro = 1; next }
    dentro && /^  [a-zA-Z_-]+:$/ { exit }
    dentro { print }
  ' "$WF"
}

echo "== concorrencia do rebuild-env =="

check "o workflow NAO tem grupo de concorrencia global" \
  "$(awk '/^concurrency:/ {n++} END {print n + 0}' "$WF")" "0"

check "o job guard fica fora de qualquer grupo" \
  "$(job_block guard | grep -c 'concurrency:' || true)" "0"

check "o job de reconstrucao tem grupo" \
  "$(job_block rebuild | grep -c 'concurrency:' || true)" "1"

# O coracao dos dois bugs: o grupo tem que ser parametrizado pelo ambiente.
# `group: rebuild-env` (fixo) poe dev e hom na mesma fila.
check "o grupo e parametrizado por matrix.env, e nao fixo" \
  "$(job_block rebuild | grep -c 'group: rebuild-\${{ matrix\.env }}' || true)" "1"

check "cancel-in-progress ligado (seguro so com o grupo por ambiente)" \
  "$(job_block rebuild | grep -c 'cancel-in-progress: true' || true)" "1"

echo
echo "== o job so nasce quando ha trabalho =="

check "condicao if: needs.guard.outputs.any" \
  "$(job_block rebuild | grep -c "if: needs\.guard\.outputs\.any == 'true'" || true)" "1"

check "a matriz vem do guard" \
  "$(job_block rebuild | grep -c 'matrix: \${{ fromJSON(needs\.guard\.outputs\.matrix) }}' || true)" "1"

check "fail-fast desligado: um ambiente nao derruba o outro" \
  "$(job_block rebuild | grep -c 'fail-fast: false' || true)" "1"

echo
echo "== procedencia e publicacao =="

check "o gatilho de PR e pull_request_target, nao pull_request" \
  "$(grep -c '^  pull_request_target:' "$WF")" "1"

check "a logica de derivacao e carregada de origin/main" \
  "$(grep -c 'git show "origin/main:\.github/scripts/\$script"' "$WF")" "1"

check "nenhum push --force sem lease em nenhum workflow" \
  "$(grep -rhoE 'git push [^|&;]*--force(\s|$)' .github/workflows/ | grep -vc 'force-with-lease' || true)" "0"

echo
printf '\033[1m%s ok, %s falha(s)\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
