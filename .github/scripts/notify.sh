#!/usr/bin/env bash
#
# notify.sh -- maquina de estado das notificacoes no PR.
#
# Regra unica: comenta em TRANSICAO DE ESTADO, nunca por execucao. A marca de
# estado e a label blocked:<env> no proprio PR -- nao ha banco, nao ha arquivo,
# nada para sincronizar. O job continua stateless; o estado mora no GitHub.
#
#   entrou em conflito e nao tinha a marca -> comenta uma vez, aplica a marca
#   continua em conflito                   -> silencio absoluto
#   voltou para o conjunto                 -> comenta "voltou", remove a marca
#   entrou por uma resolucao gravada       -> comenta uma vez, SEM marca
#   segue entrando por resolucao           -> silencio absoluto
#   saiu do conjunto por outro motivo      -> remove a marca, sem comentar
#
# O estado "resolved" nao tem label, e isso e deliberado: blocked:<env> quer
# dizer FORA do ambiente, e quem entra por resolucao esta dentro. Marcar seria
# tornar a label uma mentira e quebrar a limpeza de marcas orfas da secao 3. A
# memoria dele e o marcador invisivel no comentario -- que ja e a memoria de
# verdade do sistema; a label sempre foi o atalho barato para o caso comum.
#
# Sem isso, um job que roda a cada push transforma um conflito de meio dia em
# 40 comentarios e as pessoas param de ler os comentarios do bot.
set -euo pipefail

ENV_NAME="${ENV_NAME:?defina ENV_NAME}"
STATE_FILE="${STATE_FILE:?defina STATE_FILE}"
DRY_RUN="${DRY_RUN:-false}"
ENV_URL="${ENV_URL:-}"

BLOCKED_LABEL="blocked:$ENV_NAME"
DEPLOY_LABEL="deploy:$ENV_NAME"
if [ "$DRY_RUN" = "true" ]; then
  REPO="${GH_REPO:-dry-run/dry-run}"
else
  REPO="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
fi

log() { printf '  %s\n' "$*" >&2; }

# Label e comentario pela API REST, e nao pelos subcomandos de alto nivel do gh.
#
# `gh pr edit --add-label` e `gh pr comment` passam por GraphQL e exigem o escopo
# read:org para resolver login/slug de autores e times -- escopo que nem um PAT
# comum nem um token de instalacao de App precisam ter para fazer este trabalho.
# REST faz o mesmo com a permissao que o App ja tem (Pull requests: write).
add_label() {
  if [ "$DRY_RUN" = "true" ]; then log "[dry-run] +$2 em #$1"; return 0; fi
  gh api -X POST "repos/$REPO/issues/$1/labels" -f "labels[]=$2" --silent
}

remove_label() {
  if [ "$DRY_RUN" = "true" ]; then log "[dry-run] -$2 em #$1"; return 0; fi
  gh api -X DELETE "repos/$REPO/issues/$1/labels/$2" --silent 2>/dev/null || true
}

# Marcador invisivel no corpo do comentario. E a memoria que sobrevive a uma
# execucao cancelada no meio: a label so e aplicada DEPOIS do comentario, entao
# um cancelamento nessa janela faria a proxima execucao comentar de novo.
#
# Guardamos o ULTIMO estado comentado, e nao "ja comentei alguma vez": uma branch
# que conflita, volta, e conflita de novo precisa ser avisada nas duas vezes.
marker() { printf '<!-- rebuild-env:%s:%s -->' "$ENV_NAME" "$1"; }

last_commented_state() {
  # Gancho de teste, no mesmo espirito do CANDIDATES_JSON do assemble-env.sh:
  # um mapa {"<pr>": "conflict|back|resolved"} substitui a leitura dos
  # comentarios, e a maquina de estados inteira roda sem GitHub.
  if [ -n "${COMMENT_STATE_JSON:-}" ]; then
    jq -r --arg n "$1" '.[$n] // empty' <<<"$COMMENT_STATE_JSON"
    return 0
  fi
  gh api "repos/$REPO/issues/$1/comments?per_page=100" --paginate --jq '.[].body' 2>/dev/null \
    | grep -oE "<!-- rebuild-env:${ENV_NAME}:(conflict|back|resolved) -->" \
    | tail -1 \
    | sed -E 's/.*:(conflict|back|resolved) -->/\1/'
}

post_comment() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '\n----- comentario para #%s -----\n%s\n-----\n' "$1" "$2" >&2
    return 0
  fi
  gh api -X POST "repos/$REPO/issues/$1/comments" -f body="$2" --silent
}

# Uma unica chamada para saber quem carrega a marca hoje.
if [ -n "${BLOCKED_JSON:-}" ]; then
  BLOCKED_NOW="$BLOCKED_JSON"
else
  BLOCKED_NOW="$(gh pr list --state open --label "$BLOCKED_LABEL" --limit 100 --json number --jq '[.[].number]')"
fi
has_mark() { jq -e --argjson n "$1" 'index($n) != null' <<<"$BLOCKED_NOW" >/dev/null; }

# Quem dependia de resolucao na publicacao ANTERIOR. E o que permite detectar a
# transicao "entrava por resolucao -> agora entra limpo", que nenhuma label
# registra: a resolucao deixou de ser necessaria porque o outro PR mergeou.
RESOLVED_BEFORE="$(jq -c '.resolvedBefore // []' "$STATE_FILE")"
was_resolved() { jq -e --argjson n "$1" 'index($n) != null' <<<"$RESOLVED_BEFORE" >/dev/null; }

RES_REF="$(jq -r '.resolutions.ref // ""' "$STATE_FILE")"
RES_SHA="$(jq -r '.resolutions.sha // ""' "$STATE_FILE")"

# Linha "main + feat/x + feat/y" reaproveitada dos dois comentarios.
SUMMARY="$(jq -r '[.base.branch] + [.features[].branch] | join(" + ")' "$STATE_FILE")"

# Lista markdown do que efetivamente subiu.
PUBLISHED_LIST="$(jq -r 'if (.features | length) == 0
  then "- _(nenhuma feature: o ambiente esta igual a `main`)_"
  else (.features[] | "- #\(.pr) `\(.branch)` (@\(.author))") end' "$STATE_FILE")"

env_link() {
  if [ -n "$ENV_URL" ]; then
    printf '\n**Ambiente:** %s/version\n' "$ENV_URL"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 1. Quem ficou de fora por conflito.
# ---------------------------------------------------------------------------
while read -r row; do
  [ -n "$row" ] || continue
  pr="$(jq -r '.pr' <<<"$row")"
  branch="$(jq -r '.branch' <<<"$row")"
  against="$(jq -r '.conflictsWith // empty' <<<"$row")"
  files="$(jq -r '.files[] | "- `" + . + "`"' <<<"$row")"

  if has_mark "$pr"; then
    log "#$pr segue em conflito -> silencio (ja tem $BLOCKED_LABEL)"
    continue
  fi

  # Sem a marca, mas o ultimo comentario meu neste PR ja foi de conflito: uma
  # execucao anterior comentou e morreu antes de marcar. So repoe a marca.
  if [ "$(last_commented_state "$pr")" = "conflict" ]; then
    log "#$pr ja tinha sido avisado -> repondo so a marca"
    add_label "$pr" "$BLOCKED_LABEL"
    continue
  fi

  # Quando o vencedor entrou antes por causa de priority:high, dizer isso e o
  # que separa "o modelo tem uma regra" de "meu PR sumiu sem explicacao": ele
  # entrava ontem e hoje nao entra, e nada na branch dele mudou.
  if [ -n "$against" ]; then
    against_txt="$(jq -r --argjson n "$against" \
      '.features[] | select(.pr == $n)
       | "#\(.pr) `\(.branch)` (@\(.author))"
         + (if (.priority // 0) > 0
            then " — marcada com `priority:high`, por isso entrou no conjunto antes da sua"
            else "" end)' "$STATE_FILE")"
  else
    against_txt="a própria \`main\` — sua branch está desatualizada em relação a ela"
  fi

  BODY="$(cat <<BODY_EOF
### ⛔ Fora do ambiente \`$ENV_NAME\` nesta reconstrução

A branch \`$branch\` não entrou no conjunto publicado em \`$ENV_NAME\`: o merge conflitou.

**Conflitou com:** $against_txt

**Arquivos em conflito:**
$files

**O que subiu em \`$ENV_NAME\` sem ela:**
$PUBLISHED_LIST

Conjunto no ar: \`$SUMMARY\`$(env_link)

---

### Nada a fazer no seu PR: ele continua limpo.

**Não resolva esse conflito aqui.** \`$ENV_NAME\` é um artefato derivado — ele é
descartado e remontado do zero a partir da \`main\` a cada reconstrução. Resolver
o conflito na sua branch faria ela carregar código de uma feature que talvez
nunca seja mergeada, e esse código viajaria junto com o seu PR até a produção.

O que acontece sozinho, sem você fazer nada:

- Se o outro PR for **mergeado na \`main\`**, aí sim: rebaseie na \`main\` e resolva
  **uma vez**, contra código real e já revisado.
- Se o outro PR for **fechado** ou **perder a label \`$DEPLOY_LABEL\`**, sua branch
  volta ao conjunto na próxima reconstrução e você recebe um comentário avisando.
- Se ele estiver na frente por **\`priority:high\`** e perder essa label, a ordem
  volta a ser a do número do PR e sua branch retorna do mesmo jeito.

Seu PR segue válido: os gates rodam, o review acontece aqui, e a \`main\` continua
sendo o único caminho para produção.

<sub>🤖 \`rebuild-env\` — comento só em mudança de estado. Enquanto o conflito
persistir, silêncio. A label \`$BLOCKED_LABEL\` é a marca desse estado.</sub>
$(marker conflict)
BODY_EOF
)"

  log "#$pr entrou em conflito -> comenta + marca"
  post_comment "$pr" "$BODY"
  add_label "$pr" "$BLOCKED_LABEL"
done < <(jq -c '.excluded[]' "$STATE_FILE")

# ---------------------------------------------------------------------------
# 2. Quem esta DENTRO do conjunto -- e em que condicao.
#
# Duas situacoes moram aqui, e confundi-las seria mentir para o autor:
#
#   entrou limpo         -> ✅ o conflito acabou de verdade
#   entrou por resolucao -> ⚠️ o conflito CONTINUA existindo; o que mudou e que
#                           ha uma resolucao gravada que o job aplica. Dizer
#                           "o conflito nao existe mais" aqui seria falso, e o
#                           autor precisa saber que ha codigo rodando em
#                           $ENV_NAME que NAO esta no PR dele.
#
# Custo de API: so consulta o historico de comentarios quem PODE ter mudado de
# estado -- quem carrega a marca, quem entra por resolucao agora, e quem
# entrava por resolucao na publicacao anterior. Um PR que entrou limpo e sempre
# esteve limpo nao custa nada.
# ---------------------------------------------------------------------------
while read -r row; do
  [ -n "$row" ] || continue
  pr="$(jq -r '.pr' <<<"$row")"
  branch="$(jq -r '.branch' <<<"$row")"

  is_resolved=false
  jq -e 'has("resolvedBy")' <<<"$row" >/dev/null 2>&1 && is_resolved=true
  marked=false; has_mark "$pr" && marked=true
  before=false; was_resolved "$pr" && before=true

  # O caso esmagadoramente comum: entrou limpo, nunca esteve fora, nunca
  # dependeu de resolucao. Silencio, sem uma chamada de API.
  if [ "$is_resolved" = false ] && [ "$marked" = false ] && [ "$before" = false ]; then
    continue
  fi

  state="$(last_commented_state "$pr")"

  # -------------------------------------------------------------------------
  # 2a. Entrou por uma resolucao gravada.
  # -------------------------------------------------------------------------
  if [ "$is_resolved" = true ]; then
    if [ "$state" = "resolved" ]; then
      log "#$pr segue entrando por resolucao -> silencio"
      if [ "$marked" = true ]; then remove_label "$pr" "$BLOCKED_LABEL"; fi
      continue
    fi

    against="$(jq -r '.conflictsWith // empty' <<<"$row")"
    if [ -n "$against" ] && [ "$against" != "null" ]; then
      against_txt="$(jq -r --argjson n "$against" \
        '.features[] | select(.pr == $n) | "#\(.pr) `\(.branch)` (@\(.author))"' "$STATE_FILE")"
    else
      against_txt="a própria \`main\`"
    fi
    rr_files="$(jq -r '.resolvedBy[] | "- `" + . + "`"' <<<"$row")"

    BODY="$(cat <<BODY_EOF
### ⚠️ Dentro de \`$ENV_NAME\`, por uma resolução gravada

\`$branch\` conflita com $against_txt — e mesmo assim entrou no conjunto
publicado em \`$ENV_NAME\`. O job aplicou uma **resolução gravada** por alguém do
time, que mora fora das branches: \`$RES_REF\` @ \`${RES_SHA:0:7}\`.

**Arquivos que a resolução reconciliou:**
$rr_files

Conjunto no ar: \`$SUMMARY\`$(env_link)

---

### Essa resolução NÃO está no seu PR — e não vai para produção.

Ela é **entrada da montagem** de \`$ENV_NAME\`, não código. Sua branch continua
exatamente como você a deixou, e o merge na \`main\` não passa por aqui: ele é do
GitHub, contra o seu PR revisado.

O que muda para você:

- **Nada agora.** Sua feature está no ar em \`$ENV_NAME\` e pode ser testada.
- **Quando $against_txt for mergeado**, o conflito passa a ser contra a \`main\`.
  Aí sim você rebaseia **uma vez** e resolve de verdade, no seu PR, contra
  código já revisado. A resolução gravada expira sozinha.
- **Se qualquer uma das duas branches mexer nessa região**, a resolução deixa de
  casar e sua branch volta a ficar de fora — com o comentário de exclusão de
  sempre. A gravação nunca é aplicada a um código que ela não viu.

<sub>🤖 \`rebuild-env\` — comento só em mudança de estado. Enquanto a resolução
seguir sendo aplicada, silêncio.</sub>
$(marker resolved)
BODY_EOF
)"

    log "#$pr entrou por resolucao gravada -> comenta"
    post_comment "$pr" "$BODY"
    if [ "$marked" = true ]; then remove_label "$pr" "$BLOCKED_LABEL"; fi
    continue
  fi

  # -------------------------------------------------------------------------
  # 2b. Entrou limpo.
  # -------------------------------------------------------------------------
  if [ "$state" = "back" ]; then
    log "#$pr ja tinha sido avisado do retorno -> so removendo a marca"
    if [ "$marked" = true ]; then remove_label "$pr" "$BLOCKED_LABEL"; fi
    continue
  fi

  if [ "$before" = true ]; then
    WHY="não precisa mais da resolução gravada: agora \`$branch\` faz merge limpo
sozinha. Isso normalmente quer dizer que o PR com que ela conflitava foi
mergeado na \`main\` — vale rebasear para o seu PR ficar em dia."
  else
    WHY="o conflito que a excluía não existe mais."
  fi

  BODY="$(cat <<BODY_EOF
### ✅ De volta ao ambiente \`$ENV_NAME\`

\`$branch\` está no conjunto publicado em \`$ENV_NAME\` — $WHY

Conjunto no ar: \`$SUMMARY\`$(env_link)

$PUBLISHED_LIST

<sub>🤖 \`rebuild-env\`</sub>
$(marker back)
BODY_EOF
)"

  log "#$pr entrou limpo (antes: marcado=$marked, resolucao=$before) -> comenta"
  post_comment "$pr" "$BODY"
  if [ "$marked" = true ]; then remove_label "$pr" "$BLOCKED_LABEL"; fi
done < <(jq -c '.features[]' "$STATE_FILE")

# ---------------------------------------------------------------------------
# 3. Marcas orfas: PR carrega blocked:<env> mas nem candidato e mais (perdeu a
#    label deploy:<env>). Saiu por vontade propria -- limpa a marca, sem "voltou".
#
#    PR fechado nao aparece aqui (a busca e --state open) e nem precisa: ele nao
#    participa mais de nada.
# ---------------------------------------------------------------------------
while read -r pr; do
  [ -n "$pr" ] || continue
  if jq -e --argjson n "$pr" '.candidates | map(.pr) | index($n) != null' "$STATE_FILE" >/dev/null; then
    continue
  fi
  log "#$pr nao e mais candidato -> remove marca em silencio"
  remove_label "$pr" "$BLOCKED_LABEL"
done < <(jq -r '.[]' <<<"$BLOCKED_NOW")
