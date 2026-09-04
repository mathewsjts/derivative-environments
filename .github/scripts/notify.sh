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
#   saiu do conjunto por outro motivo      -> remove a marca, sem comentar
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

log() { printf '  %s\n' "$*" >&2; }

run_gh() {
  if [ "$DRY_RUN" = "true" ]; then
    log "[dry-run] gh $*"
  else
    gh "$@"
  fi
}

# Uma unica chamada para saber quem carrega a marca hoje.
BLOCKED_NOW="$(gh pr list --state open --label "$BLOCKED_LABEL" --limit 100 --json number --jq '[.[].number]')"
has_mark() { jq -e --argjson n "$1" 'index($n) != null' <<<"$BLOCKED_NOW" >/dev/null; }

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

  if [ -n "$against" ]; then
    against_txt="$(jq -r --argjson n "$against" \
      '.features[] | select(.pr == $n) | "#\(.pr) `\(.branch)` (@\(.author))"' "$STATE_FILE")"
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

Seu PR segue válido: os gates rodam, o review acontece aqui, e a \`main\` continua
sendo o único caminho para produção.

<sub>🤖 \`rebuild-env\` — comento só em mudança de estado. Enquanto o conflito
persistir, silêncio. A label \`$BLOCKED_LABEL\` é a marca desse estado.</sub>
BODY_EOF
)"

  log "#$pr entrou em conflito -> comenta + marca"
  if [ "$DRY_RUN" = "true" ]; then
    printf '\n----- comentario para #%s -----\n%s\n-----\n' "$pr" "$BODY" >&2
  else
    gh pr comment "$pr" --body "$BODY"
  fi
  run_gh pr edit "$pr" --add-label "$BLOCKED_LABEL"
done < <(jq -c '.excluded[]' "$STATE_FILE")

# ---------------------------------------------------------------------------
# 2. Quem voltou para o conjunto.
# ---------------------------------------------------------------------------
while read -r row; do
  [ -n "$row" ] || continue
  pr="$(jq -r '.pr' <<<"$row")"
  branch="$(jq -r '.branch' <<<"$row")"

  has_mark "$pr" || continue

  BODY="$(cat <<BODY_EOF
### ✅ De volta ao ambiente \`$ENV_NAME\`

\`$branch\` voltou ao conjunto publicado em \`$ENV_NAME\` — o conflito que a excluía
não existe mais.

Conjunto no ar: \`$SUMMARY\`$(env_link)

$PUBLISHED_LIST

<sub>🤖 \`rebuild-env\` — a marca \`$BLOCKED_LABEL\` foi removida.</sub>
BODY_EOF
)"

  log "#$pr voltou ao conjunto -> comenta + desmarca"
  if [ "$DRY_RUN" = "true" ]; then
    printf '\n----- comentario para #%s -----\n%s\n-----\n' "$pr" "$BODY" >&2
  else
    gh pr comment "$pr" --body "$BODY"
  fi
  run_gh pr edit "$pr" --remove-label "$BLOCKED_LABEL"
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
  run_gh pr edit "$pr" --remove-label "$BLOCKED_LABEL"
done < <(jq -r '.[]' <<<"$BLOCKED_NOW")
