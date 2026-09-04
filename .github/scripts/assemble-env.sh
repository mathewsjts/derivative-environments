#!/usr/bin/env bash
#
# assemble-env.sh -- monta o conjunto de um ambiente derivado.
#
# NAO faz push, NAO faz docker build, NAO comenta em PR. So monta e descreve o
# que montou num arquivo de estado JSON. Isso e proposital: assim da para rodar
# a montagem no laptop para ensaiar a demo, sem risco de publicar nada.
#
#   ENV_NAME=hom MAX_SET=5 ./.github/scripts/assemble-env.sh
#
# Contrato:
#   entrada  : ENV_NAME, MAX_SET, STATE_FILE (opcional), gh autenticado
#   saida    : branch local <ENV_NAME> montada + STATE_FILE em JSON
#   exit 0   : montou (com ou sem branches excluidas por conflito)
#   exit 2   : teto do conjunto estourado -- nao montou nada
#
# Propriedades que o job depende:
#   - Idempotente: sempre reconstroi do zero a partir de origin/main. Se o
#     conjunto montado for igual ao publicado, nao republica nada.
#   - Deterministico: as merge commits sao funcao pura das entradas (datas e
#     identidade pinadas), entao o mesmo conjunto sempre gera a mesma historia.
#   - O conteudo do ambiente anterior NUNCA entra no build. O unico dado lido
#     da branch de ambiente e o manifesto, e so para responder "o conjunto
#     mudou?" -- ver a secao 6.
set -euo pipefail

ENV_NAME="${ENV_NAME:?defina ENV_NAME (dev|hom)}"
MAX_SET="${MAX_SET:-10}"
STATE_FILE="${STATE_FILE:-$PWD/.rebuild-state.json}"

# Identidade FIXA. Nao e cosmetico: nome e email entram no hash do commit, e o
# criterio de aceite exige que duas execucoes seguidas produzam o mesmo SHA.
BOT_NAME="${BOT_NAME:-derivative-env-bot}"
BOT_EMAIL="${BOT_EMAIL:-derivative-env-bot@users.noreply.github.com}"

log() { printf '  %s\n' "$*" >&2; }
section() { printf '\n\033[1m%s\033[0m\n' "$*" >&2; }

git config user.name "$BOT_NAME"
git config user.email "$BOT_EMAIL"

# ---------------------------------------------------------------------------
# 1. Base: a main de agora. Sempre.
# ---------------------------------------------------------------------------
section "[$ENV_NAME] base"
git fetch --quiet origin main
BASE_SHA="$(git rev-parse origin/main)"
log "origin/main = $BASE_SHA"

# ---------------------------------------------------------------------------
# 2. Conjunto candidato: PRs abertos para a main com a label do ambiente.
#    Ordenado por numero do PR -- ordem estavel, previsivel e defensavel:
#    quem abriu antes entra antes, e ninguem precisa negociar prioridade.
# ---------------------------------------------------------------------------
section "[$ENV_NAME] candidatos (label deploy:$ENV_NAME)"
# CANDIDATES_JSON existe para teste: permite exercitar a montagem inteira sem
# GitHub (ver .github/scripts/test-assemble.sh). Em producao vem do gh.
if [ -n "${CANDIDATES_JSON:-}" ]; then
  CANDIDATES="$(jq -c 'sort_by(.pr)' <<<"$CANDIDATES_JSON")"
  log "usando CANDIDATES_JSON (modo teste)"
else
  CANDIDATES="$(
    gh pr list --state open --base main --label "deploy:$ENV_NAME" --limit 100 \
      --json number,headRefName,headRefOid,author \
      --jq '[.[] | {pr: .number, branch: .headRefName, author: .author.login}] | sort_by(.pr)'
  )"
fi
CANDIDATE_COUNT="$(jq 'length' <<<"$CANDIDATES")"
log "$CANDIDATE_COUNT candidato(s)"

# ---------------------------------------------------------------------------
# 3. Teto do conjunto. Estourou, o job recusa e diz quem esta ocupando espaco --
#    um ambiente com 30 features dentro nao testa nada, so parece cheio.
# ---------------------------------------------------------------------------
if [ "$CANDIDATE_COUNT" -gt "$MAX_SET" ]; then
  jq -n --arg env "$ENV_NAME" --arg base "$BASE_SHA" --argjson max "$MAX_SET" \
        --argjson candidates "$CANDIDATES" \
    '{environment:$env, base:{branch:"main", sha:$base}, capExceeded:true,
      max:$max, features:[], excluded:[], candidates:$candidates}' > "$STATE_FILE"

  {
    echo "Teto do ambiente '$ENV_NAME' estourado: $CANDIDATE_COUNT PRs marcados, maximo $MAX_SET."
    echo "Ocupando espaco agora:"
    jq -r '.[] | "  #\(.pr) \(.branch) (@\(.author))"' <<<"$CANDIDATES"
    echo "Remova a label deploy:$ENV_NAME de algum deles e rode de novo."
  } >&2
  exit 2
fi

# Traz as branches candidatas. Usamos o tip recem-buscado como SHA de registro
# (e nao o headRefOid da API) para nao montar um conjunto que ja envelheceu
# entre a chamada da API e o fetch.
if [ "$CANDIDATE_COUNT" -gt 0 ]; then
  REFSPECS=()
  while read -r refspec; do
    [ -n "$refspec" ] && REFSPECS+=("$refspec")
  done < <(jq -r '.[] | "+refs/heads/\(.branch):refs/remotes/origin/\(.branch)"' <<<"$CANDIDATES")
  git fetch --quiet origin "${REFSPECS[@]}"
fi

# ---------------------------------------------------------------------------
# 4. PASSE 1 -- descoberta.
#    Tenta cada merge para saber QUEM entra. Em conflito: registra os arquivos,
#    aborta o merge e segue para a proxima. O loop nao para -- e essa a diferenca
#    entre "uma feature ficou de fora" e "o ambiente caiu".
# ---------------------------------------------------------------------------
section "[$ENV_NAME] passe 1: descoberta"
git checkout --quiet -B "$ENV_NAME" "$BASE_SHA"

INCLUDED='[]'
EXCLUDED='[]'

while read -r row; do
  [ -n "$row" ] || continue
  pr="$(jq -r '.pr' <<<"$row")"
  branch="$(jq -r '.branch' <<<"$row")"
  author="$(jq -r '.author' <<<"$row")"
  sha="$(git rev-parse "origin/$branch")"

  if git merge --no-ff --no-edit -m "merge(env): #$pr $branch" "$sha" >/dev/null 2>&1; then
    log "OK      #$pr $branch"
    INCLUDED="$(jq -c --argjson pr "$pr" --arg b "$branch" --arg s "$sha" --arg a "$author" \
      '. + [{pr:$pr, branch:$b, sha:$s, author:$a}]' <<<"$INCLUDED")"
  else
    files="$(git diff --name-only --diff-filter=U || true)"
    git merge --abort || git reset --hard --quiet HEAD

    # Contra QUEM, exatamente?
    #
    # "Tocou o mesmo arquivo" nao serve como resposta: numa POC onde tres
    # branches editam o mesmo registry, isso aponta o culpado errado toda vez
    # que a terceira mexe noutra regiao. E o comentario no PR precisa acertar --
    # ele diz para a pessoa esperar o merge de um PR especifico.
    #
    # Entao reproduzimos o conflito em pares, que e barato (merge e instantaneo)
    # e exato:
    #   1. main + X conflita?           -> a branch esta atras da main
    #   2. main + F + X conflita?       -> o primeiro F que conflitar e a resposta
    against='null'
    probe_files="$files"

    git checkout --quiet -B __probe "$BASE_SHA"
    if git merge --no-ff --no-edit -m probe "$sha" >/dev/null 2>&1; then
      while read -r inc; do
        [ -n "$inc" ] || continue
        inc_pr="$(jq -r '.pr' <<<"$inc")"
        inc_sha="$(jq -r '.sha' <<<"$inc")"

        git checkout --quiet -B __probe "$BASE_SHA"
        if ! git merge --no-ff --no-edit -m probe-base "$inc_sha" >/dev/null 2>&1; then
          git merge --abort >/dev/null 2>&1 || true
          continue
        fi
        if ! git merge --no-ff --no-edit -m probe "$sha" >/dev/null 2>&1; then
          against="$inc_pr"
          probe_files="$(git diff --name-only --diff-filter=U || true)"
          git merge --abort >/dev/null 2>&1 || true
          break
        fi
      done < <(jq -c '.[]' <<<"$INCLUDED")
    else
      # Conflita sozinha em cima da main: nao e briga com outra feature, a
      # branch e que esta desatualizada.
      probe_files="$(git diff --name-only --diff-filter=U || true)"
      git merge --abort >/dev/null 2>&1 || true
    fi

    git checkout --quiet "$ENV_NAME"
    git branch -D __probe >/dev/null 2>&1 || true
    files="$probe_files"

    log "CONFLITO #$pr $branch (vs ${against}) -> $(tr '\n' ' ' <<<"$files")"
    EXCLUDED="$(jq -c --argjson pr "$pr" --arg b "$branch" --arg s "$sha" --arg a "$author" \
      --argjson against "$against" --arg files "$files" \
      '. + [{pr:$pr, branch:$b, sha:$s, author:$a, reason:"conflict",
             conflictsWith:$against,
             files:($files | split("\n") | map(select(length > 0)))}]' <<<"$EXCLUDED")"
  fi
done < <(jq -c '.[]' <<<"$CANDIDATES")

# ---------------------------------------------------------------------------
# 5. PASSE 2 -- montagem deterministica.
#    Agora que o conjunto final e conhecido, remontamos do zero com datas
#    pinadas. Sem isso o SHA do ambiente muda a cada execucao (data de autor e
#    de committer entram no hash do merge commit) e o criterio "rodar duas
#    vezes produz o mesmo SHA" seria impossivel de atender.
#
#    A data e funcao pura das entradas: o maior committer date entre a main e
#    as features que de fato entraram. Branches excluidas nao influenciam.
# ---------------------------------------------------------------------------
section "[$ENV_NAME] passe 2: montagem deterministica"
PINNED="$(git show -s --format=%ct "$BASE_SHA")"
while read -r inc; do
  [ -n "$inc" ] || continue
  ts="$(git show -s --format=%ct "$(jq -r '.sha' <<<"$inc")")"
  if [ "$ts" -gt "$PINNED" ]; then PINNED="$ts"; fi
done < <(jq -c '.[]' <<<"$INCLUDED")

export GIT_AUTHOR_DATE="@$PINNED +0000"
export GIT_COMMITTER_DATE="@$PINNED +0000"
log "data pinada: $PINNED ($(date -u -r "$PINNED" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$PINNED" '+%Y-%m-%dT%H:%M:%SZ'))"

git checkout --quiet -B "$ENV_NAME" "$BASE_SHA"
while read -r inc; do
  [ -n "$inc" ] || continue
  pr="$(jq -r '.pr' <<<"$inc")"
  branch="$(jq -r '.branch' <<<"$inc")"
  sha="$(jq -r '.sha' <<<"$inc")"
  # Nao pode conflitar: o passe 1 ja provou que esse subconjunto, nessa ordem, merge limpo.
  git merge --no-ff --no-edit -m "merge(env): #$pr $branch" "$sha" >/dev/null
done < <(jq -c '.[]' <<<"$INCLUDED")

# ---------------------------------------------------------------------------
# 6. O conjunto montado ja e o que esta publicado?
#
#    A comparacao e pelo CONJUNTO (base, features, excluded), lido do manifesto
#    da branch de ambiente, e nao pelo SHA. O motivo e uma armadilha real:
#
#    A montagem e deterministica, entao voltar a um conjunto ja publicado
#    reproduz o commit byte a byte. Um provedor que deduplica deploy por SHA do
#    commit -- a Vercel faz isso -- ignora esse push e NAO move o alias da
#    branch. Resultado: a branch anda, a URL fica parada num conjunto antigo,
#    sem erro em lugar nenhum.
#
#    Comparando conjunto, "nada mudou" continua sendo no-op de verdade (nao
#    republica, o SHA na branch nao muda), e "voltei a um conjunto anterior"
#    vira uma publicacao nova -- que e o que de fato aconteceu.
# ---------------------------------------------------------------------------
section "[$ENV_NAME] comparando com o publicado"

REMOTE_HEAD="$(git ls-remote origin "refs/heads/$ENV_NAME" | cut -f1)"

# Traz a branch de ambiente so para ler o manifesto dela. Continuamos montando
# do zero a partir da main -- nada do conteudo anterior entra no build.
PUBLISHED='{}'
if [ -n "$REMOTE_HEAD" ]; then
  git fetch --quiet origin "+refs/heads/$ENV_NAME:refs/remotes/origin/$ENV_NAME" 2>/dev/null || true
  PUBLISHED="$(git show "origin/$ENV_NAME:build-manifest.json" 2>/dev/null || echo '{}')"
fi

descriptor() { jq -S -c '{environment, base, features, excluded}' 2>/dev/null || echo 'null'; }

NEW_DESC="$(jq -S -c -n --arg env "$ENV_NAME" --arg base "$BASE_SHA" \
              --argjson features "$INCLUDED" --argjson excluded "$EXCLUDED" \
  '{environment:$env, base:{branch:"main", sha:$base}, features:$features, excluded:$excluded}')"
PUB_DESC="$(printf '%s' "$PUBLISHED" | descriptor)"

NOOP=false
if [ -n "$REMOTE_HEAD" ] && [ "$NEW_DESC" = "$PUB_DESC" ]; then
  NOOP=true
fi

if [ "$NOOP" = true ]; then
  # Sem commit de manifesto: o ambiente publicado ja e este. A branch remota
  # fica exatamente onde esta, com o mesmo SHA.
  ENV_HEAD="$REMOTE_HEAD"
  log "conjunto identico ao publicado -- nada a fazer"
else
  # ---------------------------------------------------------------------------
  # 7. Manifesto: o que o /version vai responder.
  #
  #    previousEnvHead registra o SHA que este ambiente substituiu. Alem de
  #    deixar a branch auto-descritiva, e o que garante que uma transicao de
  #    volta a um conjunto anterior produza um commit inedito.
  #
  #    Chaves ordenadas e zero timestamp/run-id aqui dentro: a montagem precisa
  #    continuar sendo funcao pura das entradas.
  # ---------------------------------------------------------------------------
  jq -S -n --arg env "$ENV_NAME" --arg base "$BASE_SHA" --arg prev "$REMOTE_HEAD" \
        --argjson features "$INCLUDED" --argjson excluded "$EXCLUDED" \
    '{environment:$env, base:{branch:"main", sha:$base},
      previousEnvHead:(if $prev == "" then null else $prev end),
      features:$features, excluded:$excluded}' \
    > build-manifest.json

  git add build-manifest.json
  git commit --quiet -m "chore(env): manifesto de $ENV_NAME"
  ENV_HEAD="$(git rev-parse HEAD)"
fi

log "HEAD de $ENV_NAME = $ENV_HEAD"
log "remoto           = ${REMOTE_HEAD:-<nao existe>}"
log "no-op            = $NOOP"

jq -n --arg env "$ENV_NAME" --arg base "$BASE_SHA" --arg head "$ENV_HEAD" \
      --arg remote "$REMOTE_HEAD" --argjson noop "$NOOP" \
      --argjson features "$INCLUDED" --argjson excluded "$EXCLUDED" \
      --argjson candidates "$CANDIDATES" \
  '{environment:$env, base:{branch:"main", sha:$base}, envHead:$head,
    remoteHead:(if $remote == "" then null else $remote end), noop:$noop,
    capExceeded:false, features:$features, excluded:$excluded, candidates:$candidates}' \
  > "$STATE_FILE"

section "[$ENV_NAME] pronto: $(jq -r '.features | length' "$STATE_FILE") dentro, $(jq -r '.excluded | length' "$STATE_FILE") fora"
