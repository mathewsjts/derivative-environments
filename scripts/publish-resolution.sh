#!/usr/bin/env bash
#
# publish-resolution.sh [<prA> <prB>] -- publica o rr-cache local no ref orfao.
#
# Este e o UNICO lugar que escreve em refs/heads/env-resolutions. O rebuild-env
# le esse ref e nunca escreve nele -- e nao e detalhe: com rerere ligado, o
# proprio job grava preimages dos conflitos que NAO resolveu. Sao inofensivos
# (preimage sem postimage nao faz nada), mas se o job empurrasse o cache de
# volta, o ref viraria lixeira em duas semanas.
#
# Por isso aqui tambem so sobem entradas COM postimage: uma resolucao que
# ninguem escreveu nao e uma resolucao.
#
# Ref orfao, e nao actions/cache: cache e evictavel. Se sumisse, o ambiente
# mudaria de conteudo sem nenhuma entrada ter mudado -- quebra silenciosa do
# "mesma entrada, mesma saida". Como ref, o SHA e entrada explicita e entra no
# manifesto, que e o que faz o /version conseguir dizer de onde veio o merge.
set -euo pipefail

RESOLUTIONS_REF="${RESOLUTIONS_REF:-env-resolutions}"
# Absoluto de proposito: --git-path devolve caminho RELATIVO, e o
# publish-resolution.sh faz cd para um tmpdir depois de calcular isto.
RR_CACHE="$(git rev-parse --absolute-git-dir)/rr-cache"
REPO_ROOT="$(git rev-parse --show-toplevel)"
ORIGIN_URL="$(git remote get-url origin)"

log()     { printf '  %s\n' "$*"; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Sem argumentos, deduz da branch de trabalho que o record-resolution criou.
PR_A="${1:-}"; PR_B="${2:-}"
if [ -z "$PR_A" ] || [ -z "$PR_B" ]; then
  CURRENT="$(git rev-parse --abbrev-ref HEAD)"
  case "$CURRENT" in
    rr/*-*) PR_A="${CURRENT#rr/}"; PR_A="${PR_A%%-*}"
            PR_B="${CURRENT##*-}" ;;
    *) echo "Informe os PRs: publish-resolution.sh <prA> <prB>" >&2; exit 1 ;;
  esac
  log "deduzido de $CURRENT: #$PR_A e #$PR_B"
fi

LOCAL_IDS="$(find "$RR_CACHE" -name postimage -exec dirname {} \; 2>/dev/null | xargs -n1 basename 2>/dev/null | sort || true)"
if [ -z "$LOCAL_IDS" ]; then
  echo "Nenhuma resolucao gravada no cache local." >&2
  echo "Rode ./scripts/record-resolution.sh $PR_A $PR_B, resolva e commite antes." >&2
  exit 1
fi

section "Cache local"
printf '%s\n' "$LOCAL_IDS" | sed 's/^/  /'

# ---------------------------------------------------------------------------
# Trabalhamos num repo temporario com a HISTORIA do ref, e nao com um commit
# orfao novo a cada publicacao. Assim `git log env-resolutions` conta quem
# gravou o que e quando, e o --force-with-lease tem contra o que travar: duas
# pessoas gravando ao mesmo tempo dao conflito de push, nao perda silenciosa.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
git init --quiet -b "$RESOLUTIONS_REF" .
git config user.name "$(git -C "$REPO_ROOT" config user.name || echo resolution-author)"
git config user.email "$(git -C "$REPO_ROOT" config user.email || echo resolution@example.com)"

REMOTE_SHA=""
if git fetch --quiet "$ORIGIN_URL" "refs/heads/$RESOLUTIONS_REF" 2>/dev/null; then
  REMOTE_SHA="$(git rev-parse FETCH_HEAD)"
  git reset --quiet --hard FETCH_HEAD
  log "ref existente: $(git rev-parse --short FETCH_HEAD)"
else
  log "ref ainda nao existe: primeira publicacao"
fi

mkdir -p rr-cache
BEFORE="$(ls rr-cache 2>/dev/null | sort || true)"

NEW=0
while read -r id; do
  [ -n "$id" ] || continue
  mkdir -p "rr-cache/$id"
  cp "$RR_CACHE/$id/preimage"  "rr-cache/$id/preimage"
  cp "$RR_CACHE/$id/postimage" "rr-cache/$id/postimage"
  # meta.json so para as entradas novas: reescrever a de uma resolucao antiga
  # apagaria quem gravou e quando, e e por esse arquivo que a expiracao diaria
  # sabe quais PRs manter vivos.
  if ! printf '%s\n' "$BEFORE" | grep -qx "$id"; then
    NEW=$((NEW + 1))
    jq -n --arg id "$id" --argjson a "$PR_A" --argjson b "$PR_B" \
          --arg who "$(gh api user --jq .login 2>/dev/null || git config user.email)" \
          --arg when "$(date -u +%FT%TZ)" \
      '{id:$id, prs:[$a,$b], recordedBy:$who, recordedAt:$when}' > "rr-cache/$id/meta.json"
    log "nova: $id"
  else
    log "ja publicada: $id (postimage atualizado se mudou)"
  fi
done <<< "$LOCAL_IDS"

git add -A
if git diff --cached --quiet; then
  section "Nada a publicar"
  echo "  O ref ja tem exatamente estas resolucoes."
  exit 0
fi

git commit --quiet -m "rerere: resolucao #$PR_A x #$PR_B" \
  -m "$NEW nova(s) entrada(s). Aplicada por rebuild-env em toda reconstrucao."

section "Publicando"
if [ -n "$REMOTE_SHA" ]; then
  git push --force-with-lease="refs/heads/$RESOLUTIONS_REF:$REMOTE_SHA" \
           "$ORIGIN_URL" "HEAD:refs/heads/$RESOLUTIONS_REF"
else
  git push "$ORIGIN_URL" "HEAD:refs/heads/$RESOLUTIONS_REF"
fi

# ---------------------------------------------------------------------------
# O push NAO dispara workflow, e isso nao e configuracao faltando.
#
# Em evento `push`, o GitHub Actions le os workflows do COMMIT DA BRANCH QUE
# RECEBEU O PUSH. Este ref e orfao e carrega so rr-cache/ -- nao ha
# .github/workflows/ nele, entao nenhum workflow existe para ser disparado.
#
# A alternativa seria ramificar o ref da main para ele carregar os workflows,
# mas ai ele deixa de ser um ref de dados e vira uma branch de codigo que
# ninguem sabe interpretar. Melhor manter o ref burro e disparar na mao: quem
# publica e uma pessoa, com gh na frente.
# ---------------------------------------------------------------------------
section "Disparando a reconstrucao"
if gh workflow run rebuild-env.yml -f environment=ambos 2>/dev/null; then
  log "rebuild-env disparado (dev e hom)"
else
  log "NAO consegui disparar. Rode: gh workflow run rebuild-env.yml -f environment=ambos"
fi

section "Publicado"
cat <<EOF
  $RESOLUTIONS_REF @ $(git rev-parse --short HEAD)

  Os dois ambientes sao remontados, e os PRs que passarem a entrar por resolucao
  recebem o comentario explicando que a resolucao NAO esta no PR deles.

  A gravacao expira sozinha quando #$PR_A ou #$PR_B fechar (label-ttl.yml).

  A branch de trabalho nao serve mais para nada:
    git checkout main && git branch -D rr/$PR_A-$PR_B
EOF
