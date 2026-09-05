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
#   entrada  : ENV_NAME, MAX_SET, STATE_FILE (opcional), RESOLUTIONS_REF
#              (opcional), gh autenticado
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
# 1b. Resolucoes gravadas (opcional).
#
#     Duas branches que conflitam nao podem coexistir num ambiente -- a menos
#     que alguem escreva a terceira versao do codigo. A pergunta nao e SE ela
#     existe, e onde ela mora:
#
#       numa branch de integracao -> vira branch de longa duracao com commits
#                                    que nao existem em outro lugar, que e
#                                    exatamente o que este modelo eliminou;
#       numa das features         -> a branch passa a carregar codigo de uma
#                                    feature que talvez nunca seja mergeada;
#       AQUI                      -> a resolucao vira ENTRADA da derivacao.
#
#     E o rr-cache do git rerere, versionado num ref orfao. Um humano resolve
#     uma vez (scripts/record-resolution.sh) e a maquina reaplica em toda
#     reconstrucao. As branches de feature nao sao tocadas.
#
#     Ref orfao, e NAO actions/cache: cache e evictavel. Se ele sumisse, o
#     ambiente mudaria de conteudo sem NENHUMA entrada ter mudado -- quebra
#     silenciosa do "mesma entrada, mesma saida". Como ref, o SHA e uma entrada
#     explicita, e entra no manifesto.
#
#     Sem nenhuma resolucao gravada o rerere fica DESLIGADO e a montagem e
#     byte a byte a de sempre. Quem nao usa nao paga nada.
# ---------------------------------------------------------------------------
RESOLUTIONS_REF="${RESOLUTIONS_REF:-env-resolutions}"
# Absoluto de proposito: --git-path devolve caminho RELATIVO, e o
# publish-resolution.sh faz cd para um tmpdir depois de calcular isto.
RR_CACHE="$(git rev-parse --absolute-git-dir)/rr-cache"
RESOLUTIONS_SHA=""
RESOLUTIONS_COUNT=0

# O cache do runner nunca sobrevive de uma execucao para outra, e nao pode
# mesmo: com rerere ligado o proprio job GRAVA preimages dos conflitos que NAO
# resolveu. Sao lixo (preimage sem postimage nao faz nada), mas se alguem
# "otimizar" isso com um push de volta, o ref vira lixeira. Aqui o ref e
# somente leitura -- quem escreve nele e scripts/publish-resolution.sh.
rm -rf "$RR_CACHE"

if git fetch --quiet origin \
     "+refs/heads/$RESOLUTIONS_REF:refs/remotes/origin/$RESOLUTIONS_REF" 2>/dev/null; then
  RESOLUTIONS_SHA="$(git rev-parse "origin/$RESOLUTIONS_REF")"
  mkdir -p "$RR_CACHE"
  git archive "origin/$RESOLUTIONS_REF" rr-cache 2>/dev/null \
    | tar -x -C "$(git rev-parse --absolute-git-dir)" 2>/dev/null || true
  RESOLUTIONS_COUNT="$(find "$RR_CACHE" -name postimage 2>/dev/null | wc -l | tr -d ' ')"
fi

if [ "$RESOLUTIONS_COUNT" -gt 0 ]; then
  git config rerere.enabled true
  git config rerere.autoUpdate true
  log "resolucoes: $RESOLUTIONS_COUNT de $RESOLUTIONS_REF @ $(git rev-parse --short "$RESOLUTIONS_SHA")"
else
  # Explicito, e nao "por omissao": um rerere.enabled herdado do ambiente do
  # runner mudaria a montagem sem aparecer em lugar nenhum.
  git config rerere.enabled false
  RESOLUTIONS_SHA=""
  log "resolucoes: nenhuma -- montagem identica a de sempre"
fi

# ---------------------------------------------------------------------------
# 2. Conjunto candidato: PRs abertos para a main com a label do ambiente.
#
#    A ORDEM E QUEM DECIDE O CONFLITO: quem entra primeiro fica, quem chega
#    depois e nao aplica limpo fica de fora. Por padrao a ordem e o numero do
#    PR -- estavel, previsivel e sem negociacao: quem abriu antes entra antes.
#
#    priority:high existe para o caso que essa regra atende mal: um ajuste
#    critico preso atras de um PR mais antigo que conflita com ele. A label e
#    de INTENCAO (aplicada por gente, como deploy:*) e vale para todo ambiente
#    onde o PR ja esta.
#
#    E ela para por aqui: prioridade e ORDENACAO, nao preempcao. Nada depois
#    desta secao sabe que a label existe -- passe 1, atribuicao de culpa,
#    passe 2, manifesto e notificacao herdam a ordem nova sem uma condicional.
# ---------------------------------------------------------------------------
section "[$ENV_NAME] candidatos (label deploy:$ENV_NAME)"

# Sem nenhum priority:high, isto e EXATAMENTE o sort_by(.pr) de antes: mesma
# ordem, mesmo conjunto, mesmo SHA de ambiente. Essa equivalencia e o que
# garante que a label nao mexe em quem nao a usa.
#
# O `// 0` tambem mantem as fixtures antigas de CANDIDATES_JSON validas: elas
# nao conhecem o campo. E ele fica numa variavel so para que o caminho de
# producao e o de teste nao possam divergir na ordenacao.
ORDER='map(.priority = (.priority // 0)) | sort_by([-.priority, .pr])'

# CANDIDATES_JSON existe para teste: permite exercitar a montagem inteira sem
# GitHub (ver .github/scripts/test-assemble.sh). Em producao vem do gh.
if [ -n "${CANDIDATES_JSON:-}" ]; then
  CANDIDATES="$(jq -c "$ORDER" <<<"$CANDIDATES_JSON")"
  log "usando CANDIDATES_JSON (modo teste)"
else
  # `labels` vem na MESMA chamada que ja fazemos: ler a prioridade nao custa
  # uma requisicao a mais. O `index(...) != null` e proposital -- contains
  # (["priority:high"]) faz match de substring e casaria com priority:highest.
  CANDIDATES="$(
    gh pr list --state open --base main --label "deploy:$ENV_NAME" --limit 100 \
      --json number,headRefName,headRefOid,author,labels \
      --jq '[.[] | {pr: .number, branch: .headRefName, author: .author.login,
                    priority: (if (.labels | map(.name) | index("priority:high")) != null
                               then 1 else 0 end)}]' \
    | jq -c "$ORDER"
  )"
fi
CANDIDATE_COUNT="$(jq 'length' <<<"$CANDIDATES")"
PRIORITY_COUNT="$(jq '[.[] | select(.priority > 0)] | length' <<<"$CANDIDATES")"
if [ "$PRIORITY_COUNT" -gt 0 ]; then
  log "$CANDIDATE_COUNT candidato(s), $PRIORITY_COUNT com priority:high"
else
  log "$CANDIDATE_COUNT candidato(s)"
fi

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
    # Na ordem nova, entao os prioritarios aparecem primeiro -- e marcados,
    # porque "remova a label de algum deles" precisa da informacao de quais
    # alguem ja declarou criticos.
    jq -r '.[] | "  #\(.pr) \(.branch) (@\(.author))"
                 + (if .priority > 0 then "  [priority:high]" else "" end)' <<<"$CANDIDATES"
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
# blame_conflict <sha> -- contra QUEM, exatamente?
#
# "Tocou o mesmo arquivo" nao serve como resposta: numa POC onde tres branches
# editam o mesmo registry, isso aponta o culpado errado toda vez que a terceira
# mexe noutra regiao. E o comentario no PR precisa acertar -- ele diz para a
# pessoa esperar o merge de um PR especifico.
#
# Entao reproduzimos o conflito em pares, que e barato (merge e instantaneo) e
# exato:
#   1. main + X conflita?      -> a branch esta atras da main
#   2. main + F + X conflita?  -> o primeiro F que conflitar e a resposta
#
# As sondas rodam com rerere DESLIGADO, e isso nao e detalhe. Elas perguntam
# "estas duas branches se contradizem no texto?", e uma resolucao gravada nao
# muda essa resposta -- so mudaria QUEM leva a culpa. Com rerere ligado, uma
# sonda `main + F` poderia mergear limpo por causa de uma gravacao que nao cobre
# o conjunto inteiro, F escaparia da atribuicao e o comentario diria "sua branch
# esta atrasada em relacao a main", que e falso.
#
# Chamada nos DOIS caminhos: para quem ficou de fora (o comentario de exclusao)
# e para quem entrou por resolucao (o comentario precisa nomear o par tambem --
# "voce esta em hom por uma resolucao contra #N" so e acionavel com o N).
#
# Escreve BLAME_PR (numero ou 'null') e BLAME_FILES (vazio quando so a main
# explica o conflito -- ai o caller mantem os arquivos que ja tinha).
# ---------------------------------------------------------------------------
blame_conflict() {
  local sha="$1" inc inc_pr inc_sha
  BLAME_PR='null'; BLAME_FILES=""

  git checkout --quiet -B __probe "$BASE_SHA"
  if git -c rerere.enabled=false merge --no-ff --no-edit -m probe "$sha" >/dev/null 2>&1; then
    while read -r inc; do
      [ -n "$inc" ] || continue
      inc_pr="$(jq -r '.pr' <<<"$inc")"
      inc_sha="$(jq -r '.sha' <<<"$inc")"

      git checkout --quiet -B __probe "$BASE_SHA"
      if ! git -c rerere.enabled=false merge --no-ff --no-edit -m probe-base "$inc_sha" >/dev/null 2>&1; then
        git merge --abort >/dev/null 2>&1 || true
        continue
      fi
      if ! git -c rerere.enabled=false merge --no-ff --no-edit -m probe "$sha" >/dev/null 2>&1; then
        BLAME_PR="$inc_pr"
        BLAME_FILES="$(git diff --name-only --diff-filter=U || true)"
        git merge --abort >/dev/null 2>&1 || true
        break
      fi
    done < <(jq -c '.[]' <<<"$INCLUDED")
  else
    # Conflita sozinha em cima da main: nao e briga com outra feature, a branch
    # e que esta desatualizada.
    BLAME_FILES="$(git diff --name-only --diff-filter=U || true)"
    git merge --abort >/dev/null 2>&1 || true
  fi

  git checkout --quiet "$ENV_NAME"
  git branch -D __probe >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# merge_feature <sha> <mensagem>
#
# Existe por UM motivo, e ele e a armadilha central de usar rerere aqui:
#
#   COM UMA RESOLUCAO GRAVADA, `git merge` AINDA SAI COM CODIGO 1.
#
# Ele aplica a resolucao, deixa a arvore inteira resolvida e staged, e para
# esperando o `git commit` -- imprimindo "Staged '<arquivo>' using previous
# resolution.". Quem olhar so o codigo de saida -- que e o que este script fazia
# -- exclui do ambiente uma branch que na verdade entrou, e o rerere nao serve
# para nada.
#
# O sinal certo e o INDICE: nenhum caminho em estado U.
#
# Escreve:
#   MERGE_RESULT    clean | resolved | conflict
#   MERGE_RR_FILES  arquivos resolvidos pela gravacao (so em resolved)
#   MERGE_FILES     arquivos em conflito (so em conflict; o merge ja foi abortado)
# ---------------------------------------------------------------------------
merge_feature() {
  local sha="$1" msg="$2" out
  MERGE_RESULT=""; MERGE_RR_FILES=""; MERGE_FILES=""

  if out="$(git merge --no-ff --no-edit -m "$msg" "$sha" 2>&1)"; then
    MERGE_RESULT=clean
    return 0
  fi

  # MERGE_HEAD confirma que existe um merge em curso. Sem esta guarda, uma falha
  # de outra natureza ("not something we can merge", ref invalido) tambem daria
  # indice limpo, e commitariamos um merge que nunca comecou.
  if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
     && [ -z "$(git diff --name-only --diff-filter=U)" ]; then
    MERGE_RR_FILES="$(sed -n "s/^Staged '\(.*\)' using previous resolution\.$/\1/p" <<<"$out")"
    git commit --quiet --no-edit
    MERGE_RESULT=resolved
    return 0
  fi

  # Resolucao PARCIAL cai aqui de proposito: se sobrou um caminho em U, a
  # gravacao nao cobre este merge e a branch fica de fora, como sempre.
  MERGE_FILES="$(git diff --name-only --diff-filter=U || true)"
  git merge --abort >/dev/null 2>&1 || git reset --hard --quiet HEAD
  MERGE_RESULT=conflict
  return 1
}

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

  # O rank so viaja para o manifesto daqui para baixo -- a decisao que ele
  # tomava (a ordem) ja foi tomada na secao 2.
  #
  # E ele e OMITIDO quando e 0, o que nao e cosmetico: mantem o descritor de um
  # conjunto sem prioridades byte a byte igual ao ja publicado. Com a chave
  # sempre presente, a comparacao da secao 6 veria um campo novo e republicaria
  # todo ambiente no primeiro rebuild apos o deploy desta feature -- churn puro,
  # sem nada ter mudado de verdade.
  prio="$(jq -r '.priority' <<<"$row")"
  if [ "$prio" -gt 0 ]; then mark=" [priority:high]"; else mark=""; fi

  if merge_feature "$sha" "merge(env): #$pr $branch"; then
    # resolvedBy e OMITIDO quando vazio, pelo mesmo motivo de `priority`: um
    # conjunto sem resolucao nenhuma precisa produzir um descritor byte a byte
    # igual ao ja publicado, senao o primeiro rebuild depois desta feature
    # republica todo ambiente sem nada ter mudado.
    rr='[]'
    rr_against='null'
    if [ "$MERGE_RESULT" = resolved ]; then
      rr="$(jq -c -R -s 'split("\n") | map(select(length > 0))' <<<"$MERGE_RR_FILES")"
      # Quem entrou por resolucao ainda conflita -- so nao ficou de fora. O
      # comentario no PR precisa do par para ser acionavel ("quando #N mergear,
      # voce rebaseia uma vez"), entao a mesma sonda de sempre roda aqui.
      blame_conflict "$sha"
      rr_against="$BLAME_PR"
      log "OK*     #$pr $branch$mark (resolucao gravada vs ${rr_against}: $(tr '\n' ' ' <<<"$MERGE_RR_FILES"))"
    else
      log "OK      #$pr $branch$mark"
    fi
    INCLUDED="$(jq -c --argjson pr "$pr" --arg b "$branch" --arg s "$sha" --arg a "$author" \
      --argjson prio "$prio" --argjson rr "$rr" --argjson against "$rr_against" \
      '. + [{pr:$pr, branch:$b, sha:$s, author:$a}
            + (if $prio > 0 then {priority:$prio} else {} end)
            + (if ($rr | length) > 0
               then {resolvedBy:$rr, conflictsWith:$against} else {} end)]' <<<"$INCLUDED")"
  else
    files="$MERGE_FILES"

    blame_conflict "$sha"
    against="$BLAME_PR"
    files="${BLAME_FILES:-$files}"

    log "CONFLITO #$pr $branch$mark (vs ${against}) -> $(tr '\n' ' ' <<<"$files")"
    EXCLUDED="$(jq -c --argjson pr "$pr" --arg b "$branch" --arg s "$sha" --arg a "$author" \
      --argjson against "$against" --arg files "$files" --argjson prio "$prio" \
      '. + [{pr:$pr, branch:$b, sha:$s, author:$a, reason:"conflict",
             conflictsWith:$against,
             files:($files | split("\n") | map(select(length > 0)))}
            + (if $prio > 0 then {priority:$prio} else {} end)]' <<<"$EXCLUDED")"
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
  # Nao pode conflitar: o passe 1 ja provou que esse subconjunto, nessa ordem,
  # merge limpo -- eventualmente com a ajuda de uma resolucao gravada, que e a
  # MESMA nos dois passes (o cache nao muda no meio da execucao). Por isso o
  # passe 2 tambem precisa do merge_feature: sem ele, um merge resolvido pelo
  # rerere derrubaria o job aqui, com o indice limpo e exit 1.
  merge_feature "$sha" "merge(env): #$pr $branch" || {
    echo "ERRO: #$pr $branch conflitou no passe 2, que o passe 1 provou impossivel." >&2
    exit 1
  }
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

# Quem no conjunto ja dependia de resolucao na publicacao ANTERIOR. E a memoria
# que o notify.sh usa para saber que "entrou por resolucao" virou "entra limpo"
# -- transicao que merece um comentario e que nenhuma label registra. Sai de
# graca: o manifesto publicado ja foi lido acima.
RESOLVED_BEFORE="$(jq -c '[.features[]? | select(has("resolvedBy")) | .pr]' <<<"$PUBLISHED" 2>/dev/null || echo '[]')"

# ---------------------------------------------------------------------------
# `resolutions` entra no descritor SO quando alguma feature de fato dependeu de
# uma resolucao. Os dois lados dessa condicao sao necessarios:
#
#   presente quando ha dependencia -- senao regravar a resolucao do MESMO par
#     (outro postimage, mesmo id de conflito) produziria conjunto igual, o teste
#     de "nada mudou" daria no-op e o ambiente seguiria servindo a resolucao
#     velha. E a mesma familia de bug do previousEnvHead: a branch parada, sem
#     erro em lugar nenhum.
#
#   ausente quando nao ha -- senao gravar uma resolucao para um par que nao esta
#     em hom mudaria o SHA do ref e republicaria dev e hom a toa.
#
# O preco aceito e o meio-termo: gravar qualquer resolucao republica os
# ambientes que ja usam alguma. Raro (gravar e ato humano e deliberado) e
# seguro na direcao certa.
# ---------------------------------------------------------------------------
RESOLUTIONS_JSON='null'
if [ -n "$RESOLUTIONS_SHA" ] && jq -e 'any(.[]; has("resolvedBy"))' <<<"$INCLUDED" >/dev/null; then
  RESOLUTIONS_JSON="$(jq -c -n --arg ref "$RESOLUTIONS_REF" --arg sha "$RESOLUTIONS_SHA" \
    '{ref:$ref, sha:$sha}')"
fi

descriptor() {
  jq -S -c '{environment, base, features, excluded}
            + (if (.resolutions // null) != null then {resolutions:.resolutions} else {} end)' \
    2>/dev/null || echo 'null'
}

NEW_DESC="$(jq -S -c -n --arg env "$ENV_NAME" --arg base "$BASE_SHA" \
              --argjson features "$INCLUDED" --argjson excluded "$EXCLUDED" \
              --argjson resolutions "$RESOLUTIONS_JSON" \
  '{environment:$env, base:{branch:"main", sha:$base}, features:$features, excluded:$excluded}
   + (if $resolutions != null then {resolutions:$resolutions} else {} end)')"
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
        --argjson resolutions "$RESOLUTIONS_JSON" \
    '{environment:$env, base:{branch:"main", sha:$base},
      previousEnvHead:(if $prev == "" then null else $prev end),
      features:$features, excluded:$excluded}
     + (if $resolutions != null then {resolutions:$resolutions} else {} end)' \
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
      --argjson resolutions "$RESOLUTIONS_JSON" --argjson resolvedBefore "$RESOLVED_BEFORE" \
  '{environment:$env, base:{branch:"main", sha:$base}, envHead:$head,
    remoteHead:(if $remote == "" then null else $remote end), noop:$noop,
    capExceeded:false, features:$features, excluded:$excluded, candidates:$candidates,
    resolutions:$resolutions, resolvedBefore:$resolvedBefore}' \
  > "$STATE_FILE"

RESOLVED_NOW="$(jq -r '[.features[] | select(has("resolvedBy"))] | length' "$STATE_FILE")"
section "[$ENV_NAME] pronto: $(jq -r '.features | length' "$STATE_FILE") dentro, $(jq -r '.excluded | length' "$STATE_FILE") fora$([ "$RESOLVED_NOW" -gt 0 ] && echo " ($RESOLVED_NOW por resolucao gravada)")"
