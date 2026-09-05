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
PRWF=.github/workflows/pr-gates.yml

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
# Segundo argumento opcional: o workflow (padrao, o rebuild-env).
job_block() {
  awk -v alvo="  $1:" '
    $0 == alvo { dentro = 1; next }
    dentro && /^  [a-zA-Z_-]+:$/ { exit }
    dentro { print }
  ' "${2:-$WF}"
}

# O bloco de um passo = da linha "      - name: <nome>" ate o proximo passo
# (ou o fim do job).
step_block() {
  awk -v alvo="      - name: $1" '
    $0 == alvo { dentro = 1; next }
    dentro && /^      - name:/ { exit }
    dentro && /^  [a-zA-Z_-]+:$/ { exit }
    dentro { print }
  ' "${2:-$WF}"
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

# ---------------------------------------------------------------------------
# priority:high reordena o conjunto, entao aplica-la PRECISA reconstruir. Se o
# guard parar de reconhecer a label, nada quebra e nada avisa: a label fica sem
# efeito ate o proximo push na branch, e a feature parece simplesmente nao
# funcionar. Por isso o gatilho e uma invariante, e nao so um teste do assemble.
# ---------------------------------------------------------------------------
echo
echo "== gatilho do priority:high =="

check "o guard reconhece priority:high" \
  "$(job_block guard | grep -c 'CHANGED_LABEL" = "priority:high"' || true)" "1"

check "e decide pelas labels do PR, sem chamada de API a mais" \
  "$(job_block guard | grep -c 'PR_LABELS' || true)" "2"

check "o filtro de blocked:* continua vindo antes de tudo" \
  "$(job_block guard | grep -c 'blocked:\*)' || true)" "1"

# ---------------------------------------------------------------------------
# Resolucoes gravadas (git rerere). Duas invariantes, e as duas ja seriam bugs
# silenciosos -- a familia de erro que este arquivo existe para pegar.
#
#   1. Gravar ou expirar uma resolucao muda QUEM entra no conjunto sem que
#      nenhuma branch ou label mude -- e o push no ref NAO dispara nada, porque
#      em evento `push` o Actions le os workflows da branch que recebeu o push e
#      aquele ref e orfao, so com rr-cache/. Sem o `gh workflow run` explicito
#      nos dois escritores, a pessoa grava a resolucao, nada acontece, e o
#      ambiente so muda no proximo evento qualquer -- sem erro em lugar nenhum.
#
#   2. O ref e SOMENTE LEITURA para o job. Com rerere ligado, o proprio job
#      grava preimages dos conflitos que NAO resolveu; se ele empurrasse o cache
#      de volta, o ref viraria lixeira e a pergunta "quais resolucoes estao
#      vivas?" deixaria de ter resposta. Quem escreve e o publish-resolution.sh
#      (humano) e a expiracao do label-ttl.
# ---------------------------------------------------------------------------
echo
echo "== resolucoes gravadas =="

check "o nome do ref e definido uma vez so, no env do workflow" \
  "$(grep -c '^  RESOLUTIONS_REF: env-resolutions$' "$WF")" "1"

# O ramo do guard fica (a decisao esta certa se a forma do ref mudar), mas quem
# de fato dispara sao os dois escritores do ref. Testar so o guard daria falsa
# seguranca -- foi exatamente o erro que este bloco existe para nao repetir.
check "o guard reconhece push no ref de resolucoes" \
  "$(job_block guard | grep -c 'REF_NAME" = "\$RESOLUTIONS_REF"' || true)" "1"

check "e o guard diz que esse ramo nao e alcancado hoje" \
  "$(job_block guard | grep -c 'NA PRATICA ESTE RAMO NAO E ALCANCADO HOJE' || true)" "1"

check "publish-resolution.sh dispara a reconstrucao explicitamente" \
  "$(grep -cE '^if gh workflow run rebuild-env\.yml' scripts/publish-resolution.sh)" "1"

check "e a expiracao do label-ttl tambem" \
  "$(grep -c 'gh workflow run rebuild-env.yml' .github/workflows/label-ttl.yml)" "1"

check "e o passo de montagem recebe o mesmo nome de ref" \
  "$(step_block "Montar o conjunto de \${{ matrix.env }}" | grep -c 'RESOLUTIONS_REF: \${{ env\.RESOLUTIONS_REF }}' || true)" "1"

check "o rebuild-env NUNCA faz push no ref de resolucoes" \
  "$(grep -cE 'git push[^|&;]*(env-resolutions|RESOLUTIONS_REF)' "$WF" || true)" "0"

check "o assemble apaga o cache local antes de carregar o do ref" \
  "$(grep -c 'rm -rf "\$RR_CACHE"' .github/scripts/assemble-env.sh)" "1"

check "e desliga o rerere explicitamente quando nao ha resolucao" \
  "$(grep -c 'git config rerere.enabled false' .github/scripts/assemble-env.sh)" "1"

# As sondas de atribuicao de culpa nao podem enxergar resolucao: elas perguntam
# "estas duas branches se contradizem no texto?". Com rerere ligado nelas, o
# comentario passaria a culpar a main por um conflito entre duas features.
check "as sondas rodam com rerere desligado" \
  "$(grep -c 'git -c rerere.enabled=false merge' .github/scripts/assemble-env.sh)" "3"

check "a expiracao das resolucoes usa lease, como todo push deste repo" \
  "$(grep -c 'force-with-lease="refs/heads/\${RESOLUTIONS_REF}' .github/workflows/label-ttl.yml)" "1"

# ---------------------------------------------------------------------------
# pr-gates: a main passou a ter CI, e com ela um evento onde
# `github.event.pull_request.number` e VAZIO.
#
# O grupo antigo (`pr-gates-${{ ...number }}`) viraria o mesmo `pr-gates-` para
# todo merge na main: o segundo merge cancelaria o CI do primeiro, e o commit
# cancelado nao seria reavaliado por ninguem. E a terceira porta de entrada do
# mesmo bug dos PRs #10 e #11 -- trabalho cancelado que ninguem refaz.
#
# A regra continua sendo uma so: o grupo e o RECURSO protegido. Em PR o recurso
# e o PR (push novo subsome o anterior, cancelar e seguro); em push na main o
# recurso e o COMMIT, e um merge nao subsome o anterior.
# ---------------------------------------------------------------------------
echo
echo "== concorrencia do pr-gates =="

check "os gates rodam tambem em push na main" \
  "$(awk '/^  push:$/ {n++} END {print n + 0}' "$PRWF")" "1"

check "o grupo distingue push de PR (fallback para github.sha)" \
  "$(grep -c 'group: pr-gates-\${{ github\.event\.pull_request\.number || github\.sha }}' "$PRWF")" "1"

check "cancel-in-progress condicionado ao evento" \
  "$(grep -c "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$PRWF")" "1"

check "nenhum cancel-in-progress incondicional (cancelaria o CI da main)" \
  "$(grep -c 'cancel-in-progress: true' "$PRWF")" "0"

check "o gate de sincronia nao roda em push (nao existe refs/pull/N/head)" \
  "$(grep -c "if: \${{ !cancelled() && github.event_name == 'pull_request' }}" "$PRWF")" "1"

# ---------------------------------------------------------------------------
# `sincronia com a main` e um PASSO do job `gates do PR`, que e contexto exigido
# pelo ruleset. Se ele reprovar, uma branch atras da main trava o merge -- ou
# seja, o `strict` de volta pela porta dos fundos, e na versao "fotografada":
# bloqueia conforme o ultimo push do PR viu e nao percebe a main andando depois.
#
# A decisao esta escrita em SETUP.md, secao 3b: prevencao O(N x PRs abertos)
# trocada pela deteccao O(1) dos gates rodando na propria main. Este bloco
# existe para que reintroduzir meia-strict aqui custe um teste vermelho, e nao
# uma descoberta em producao.
# ---------------------------------------------------------------------------
echo
echo "== sincronia com a main avisa, nao reprova =="

check "emite ::warning" \
  "$(step_block "sincronia com a main" "$PRWF" | grep -c '::warning title=Branch desatualizada' || true)" "1"

check "nao emite ::error" \
  "$(step_block "sincronia com a main" "$PRWF" | grep -c '::error' || true)" "0"

check "nao sai com codigo de erro" \
  "$(step_block "sincronia com a main" "$PRWF" | grep -cE '^ *exit 1$' || true)" "0"

# ---------------------------------------------------------------------------
# Os nomes sao contrato com o ruleset "main protegida", que exige status check
# POR NOME. Renomear um job faz o contexto exigido nunca mais reportar, e todo
# PR aberto trava para sempre esperando um check que nao existe. Nao e um bug
# silencioso como os de cima -- e o oposto, um bug barulhento demais -- mas o
# custo de errar e o mesmo repositorio parado.
# ---------------------------------------------------------------------------
echo
echo "== contrato de nome com o ruleset =="

check "o job de gates continua se chamando 'gates do PR'" \
  "$(grep -c '^    name: gates do PR$' "$PRWF")" "1"

check "o job do Sonar continua se chamando 'SonarCloud'" \
  "$(grep -c '^    name: SonarCloud$' "$PRWF")" "1"

echo
printf '\033[1m%s ok, %s falha(s)\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
