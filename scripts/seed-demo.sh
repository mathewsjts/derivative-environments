#!/usr/bin/env bash
#
# seed-demo.sh -- cria o estado inicial da demo. Idempotente.
#
# Tres features, desenhadas para provar que a exclusao por conflito e cirurgica:
#
#   feat/a-user-endpoint     registra no BLOCO DE FEATURES de src/routes/index.ts
#   feat/b-auth-endpoint     registra no MESMO anchor -> conflita com A
#   feat/c-metrics-endpoint  registra no BLOCO DE OBSERVABILIDADE -> nao conflita
#
# C tocar o mesmo arquivo e proposital. A objecao mais provavel da plateia e
# "se todo mundo mexe no registry, o ambiente inteiro trava". C mexe no registry,
# conflita com ninguem e sobe junto com A. A exclusao e por REGIAO, nao por
# arquivo.
#
# LABELS NO SEED: so deploy:dev, e so em A e C.
#   - dev nasce com main + a + c: da para mostrar o modelo funcionando no
#     segundo zero da apresentacao, sem esperar CI.
#   - hom nasce vazia: e o ambiente que voce monta ao vivo, do zero.
#   - B nasce sem label nenhuma: o primeiro comentario de conflito da vida dela
#     acontece no palco, no bloco 3 do DEMO.md.
#
# Uso:
#   ./scripts/seed-demo.sh            cria o que faltar
#   ./scripts/seed-demo.sh --reset    fecha os PRs, apaga as branches e recria
set -euo pipefail

RESET=false
if [ "${1:-}" = "--reset" ]; then RESET=true; fi

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
BRANCHES=(feat/a-user-endpoint feat/b-auth-endpoint feat/c-metrics-endpoint)

log()     { printf '  %s\n' "$*"; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# Pre-condicoes. Falhar aqui e muito melhor do que falhar no meio.
# ---------------------------------------------------------------------------
section "Pre-condicoes"
gh auth status >/dev/null 2>&1 || { echo "gh nao autenticado: rode 'gh auth login'." >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "Worktree suja. Commite ou guarde antes." >&2; exit 1; }
git fetch --quiet origin main
git rev-parse --verify --quiet origin/main >/dev/null || { echo "origin/main nao existe. Faca push da main antes." >&2; exit 1; }
ORIGINAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
log "repo   = $REPO"
log "main   = $(git rev-parse --short origin/main)"
log "voltar = $ORIGINAL_BRANCH"

# ---------------------------------------------------------------------------
# A main pre-demo: os quatro blocos de registro vazios, sem nenhuma feature
# dentro.
#
# Isto e uma pre-condicao de verdade, nao um detalhe: o bloco 5 do DEMO.md manda
# mergear o PR de A na main. Ou seja, todo ensaio COMPLETO termina com a main
# carregando a feature A -- e o seed seguinte quebra de um jeito silencioso.
# As branches nascem de origin/main, o insert_before encontra o marcador que ja
# tem a linha de A logo acima e insere uma SEGUNDA copia. Import duplicado,
# TypeScript quebrado, e o diff do PR de A vira uma linha repetida em vez de
# uma feature. Nada disso falha aqui: falha no palco.
#
# Checamos os marcadores, e nao a existencia de src/routes/users.ts, porque o
# que o insert_before quebra e o marcador. E o marcador que tem que estar limpo.
# ---------------------------------------------------------------------------
main_esta_limpa() {
  local idx m
  idx="$(git show origin/main:src/routes/index.ts 2>/dev/null)" || return 1
  for m in feature-imports feature-routes observability-imports observability-routes; do
    printf '%s\n' "$idx" | grep -A1 -- "// $m:start" | grep -q -- "// $m:end" || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Rebobina a main revertendo as features de demo que foram mergeadas nela.
#
# Por PR, e nao por force-push, porque a main e protegida por um ruleset com
# non_fast_forward e bypass_actors vazio -- nem o dono do repo passa. Isso e
# proposital e o script nao contorna: a demo defende que a main so muda por PR,
# e seria estranho o script dela abrir uma excecao para si mesmo.
# ---------------------------------------------------------------------------
rebobinar_main() {
  local rewind_branch="chore/rebobina-demo"
  local b sha s pr

  # Os merges das branches de demo que estao mesmo na main. `gh pr list` sozinho
  # nao basta: um PR pode estar marcado como merged e ter sido revertido depois,
  # e ai o merge commit ja nao e ancestral da main.
  local shas=()
  for b in "${BRANCHES[@]}"; do
    while read -r sha; do
      [ -n "$sha" ] || continue
      git merge-base --is-ancestor "$sha" origin/main 2>/dev/null && shas+=("$sha")
    done < <(gh pr list --state merged --head "$b" --json mergeCommit --jq '.[].mergeCommit.oid // empty')
  done

  if [ "${#shas[@]}" -eq 0 ]; then
    echo "  A main tem feature de demo dentro, mas nao achei o merge para reverter." >&2
    echo "  Provavelmente alguem commitou direto. Resolva a mao e rode de novo." >&2
    exit 1
  fi

  # Do mais novo para o mais velho: revert na ordem cronologica inversa. Fora
  # dessa ordem, o revert de um merge antigo tenta desfazer linhas que um merge
  # mais novo ja mexeu, e conflita.
  local ordered=()
  while read -r sha; do
    for s in ${shas[@]+"${shas[@]}"}; do [ "$s" = "$sha" ] && ordered+=("$sha"); done
  done < <(git rev-list origin/main)

  if [ "${#ordered[@]}" -eq 0 ]; then
    echo "  Nenhum merge de demo alcancavel a partir da main. Nada a reverter." >&2
    exit 1
  fi

  git checkout --quiet -B "$rewind_branch" origin/main
  for sha in ${ordered[@]+"${ordered[@]}"}; do
    # Squash e merge commit se revertem diferente, e o DEMO.md diz "Squash ou
    # Merge, tanto faz" -- entao os dois formatos aparecem aqui. O -m 1 e
    # obrigatorio num merge (qual mainline desfazer) e ilegal num squash, que
    # e commit comum de um pai so.
    if [ "$(git rev-list --parents -n1 "$sha" | wc -w)" -ge 3 ]; then
      git revert --no-edit -m 1 "$sha" >/dev/null
    else
      git revert --no-edit "$sha" >/dev/null
    fi
    log "revertido $(git rev-parse --short "$sha")"
  done

  git push --quiet --force --set-upstream origin "$rewind_branch"
  pr="$(gh pr list --state open --head "$rewind_branch" --json number --jq '.[0].number // empty')"
  if [ -z "$pr" ]; then
    pr="$(gh pr create --base main --head "$rewind_branch" \
      --title "chore(demo): rebobina a main para o estado pre-demo" \
      --body "Reverte as features de demo mergeadas na main para que o \`seed-demo.sh --reset\` possa recriar as branches a partir de uma main limpa.

Aberto automaticamente pelo \`scripts/seed-demo.sh --reset\`." | grep -oE '[0-9]+$')"
  fi
  log "PR #$pr aberto -- esperando 'gates do PR' e SonarCloud"

  if ! gh pr checks "$pr" --watch --fail-fast >/dev/null 2>&1; then
    echo "  Os gates do PR #$pr nao passaram. Resolva e rode o seed de novo." >&2
    exit 1
  fi
  gh pr merge "$pr" --merge --delete-branch >/dev/null
  git fetch --quiet origin main
  git branch -D "$rewind_branch" >/dev/null 2>&1 || true
  log "main rebobinada: $(git rev-parse --short origin/main)"
}

if ! main_esta_limpa; then
  if [ "$RESET" = true ]; then
    log "main = tem feature de demo dentro, vou rebobinar no Reset"
  else
    echo "A main tem uma feature de demo mergeada dentro dela." >&2
    echo "Recriar as branches a partir dela duplicaria a linha de registro e quebraria o build." >&2
    echo "Rode: ./scripts/seed-demo.sh --reset" >&2
    exit 1
  fi
fi

section "Labels"
./scripts/create-labels.sh >/dev/null
log "deploy:dev deploy:hom priority:high blocked:dev blocked:hom"

# ---------------------------------------------------------------------------
# --reset: derruba tudo para poder ensaiar a demo quantas vezes quiser.
# ---------------------------------------------------------------------------
if [ "$RESET" = true ]; then
  section "Reset"

  # Antes de qualquer destruicao: se a main nao voltar ao estado pre-demo, nao
  # adianta recriar branch nenhuma. Falhar aqui e muito melhor do que falhar
  # depois de ja ter fechado os PRs e apagado os ambientes.
  if ! main_esta_limpa; then
    rebobinar_main
  fi
  for b in "${BRANCHES[@]}"; do
    pr="$(gh pr list --state open --head "$b" --json number --jq '.[0].number // empty')"
    if [ -n "$pr" ]; then
      gh pr close "$pr" >/dev/null 2>&1 \
        || gh api -X PATCH "repos/$REPO/pulls/$pr" -f state=closed --silent
      log "PR #$pr fechado ($b)"
    fi
    git push --quiet origin --delete "$b" >/dev/null 2>&1 && log "branch remota $b apagada" || true
    git branch -D "$b" >/dev/null 2>&1 && log "branch local $b apagada" || true
  done
  for env_name in dev hom; do
    git push --quiet origin --delete "$env_name" >/dev/null 2>&1 && log "ambiente $env_name apagado" || true
  done

  # -------------------------------------------------------------------------
  # Resolucoes gravadas.
  #
  # Fechar e recriar os PRs nao limpa isto: o rr-cache e indexado pelo CONTEUDO
  # do conflito, nao pelo numero do PR. Como o seed recria as branches com
  # exatamente as mesmas insercoes, o conflito reproduzido tem o MESMO preimage
  # -- e uma gravacao de um ensaio anterior voltaria a se aplicar sozinha, com
  # os PRs novos. A demo comecaria com B ja dentro de hom, e o bloco 3 (o
  # conflito) simplesmente nao aconteceria.
  #
  # Tres lugares, porque o estado mora em tres lugares:
  #   remoto   o ref env-resolutions
  #   local    o rr-cache do clone de quem gravou
  #   config   rerere.enabled/autoUpdate, escritos pelo record-resolution.sh e
  #            pelo assemble-env.sh quando alguem ensaia a montagem no laptop
  # -------------------------------------------------------------------------
  RESOLUTIONS_REF="${RESOLUTIONS_REF:-env-resolutions}"
  git push --quiet origin --delete "$RESOLUTIONS_REF" >/dev/null 2>&1 \
    && log "ref $RESOLUTIONS_REF apagado" || true

  RR_CACHE="$(git rev-parse --absolute-git-dir)/rr-cache"
  if [ -d "$RR_CACHE" ]; then
    rm -rf "$RR_CACHE"
    log "rr-cache local apagado"
  fi

  # As branches de trabalho que o record-resolution.sh cria (rr/<a>-<b>).
  while read -r b; do
    [ -n "$b" ] || continue
    git branch -D "$b" >/dev/null 2>&1 && log "branch de trabalho $b apagada" || true
  done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/rr/*')

  if [ -n "$(git config --local --get rerere.enabled || true)" ]; then
    git config --local --unset-all rerere.enabled || true
    git config --local --unset-all rerere.autoUpdate || true
    log "config local de rerere removida"
  fi
fi

# ---------------------------------------------------------------------------
# Helper: insere uma linha imediatamente ANTES de um marcador.
#
# E aqui que o conflito nasce ou nao nasce. A e B usam o MESMO marcador, entao
# escrevem no mesmo byte-offset e o git nao tem como reconciliar sozinho.
# Nao e conflito artificial: e exatamente o que acontece quando duas pessoas
# adicionam uma rota no mesmo registry central na mesma semana.
# ---------------------------------------------------------------------------
insert_before() {
  local marker="$1" line="$2" file="$3"
  awk -v m="$marker" -v l="$line" 'index($0, m) { print l } { print }' "$file" > "$file.seed.tmp"
  mv "$file.seed.tmp" "$file"
}

open_pr() {
  local branch="$1" title="$2" body="$3"
  git push --quiet --set-upstream origin "$branch"
  log "PR aberto: $(gh pr create --base main --head "$branch" --title "$title" --body "$body")"
}

# Labels pela API REST, nao por `gh pr edit --add-label`: o subcomando passa por
# GraphQL e exige o escopo read:org, que um PAT comum nao tem. REST resolve com
# o escopo repo. Idempotente -- aplicar duas vezes nao duplica nada.
ensure_labels() {
  local branch="$1"; shift
  local pr
  pr="$(gh pr list --state open --head "$branch" --json number --jq '.[0].number // empty')"
  [ -n "$pr" ] || { log "sem PR aberto para $branch, nao rotulei"; return 0; }
  if [ "$#" -eq 0 ]; then
    log "PR #$pr sem label (de proposito)"
    return 0
  fi
  local args=()
  local l
  for l in "$@"; do args+=(-f "labels[]=$l"); done
  gh api -X POST "repos/$REPO/issues/$pr/labels" "${args[@]}" --silent
  log "PR #$pr labels: $*"
}

exists() {
  git rev-parse --verify --quiet "origin/$1" >/dev/null \
    && [ -n "$(gh pr list --state open --head "$1" --json number --jq '.[0].number // empty')" ]
}

# ---------------------------------------------------------------------------
# feat/a-user-endpoint -- bloco de features
# ---------------------------------------------------------------------------
section "feat/a-user-endpoint"
if exists feat/a-user-endpoint; then
  log "ja existe com PR aberto, pulando a criacao (use --reset para recriar)"
else
  git checkout --quiet -B feat/a-user-endpoint origin/main

  cat > src/routes/users.ts <<'EOF'
import { Router } from 'express';

export const usersRouter = Router();

usersRouter.get('/', (_req, res) => {
  res.json({
    feature: 'a-user-endpoint',
    users: [
      { id: 1, name: 'Ada' },
      { id: 2, name: 'Grace' },
    ],
  });
});
EOF

  cat > test/users.test.ts <<'EOF'
import request from 'supertest';
import { describe, expect, it } from 'vitest';

import { createApp } from '../src/app';

describe('GET /users', () => {
  it('lista usuarios', async () => {
    const res = await request(createApp()).get('/users');
    expect(res.status).toBe(200);
    expect(res.body.feature).toBe('a-user-endpoint');
    expect(res.body.users).toHaveLength(2);
  });
});
EOF

  insert_before "// feature-imports:end" "import { usersRouter } from './users';" src/routes/index.ts
  insert_before "// feature-routes:end"  "  app.use('/users', usersRouter);"       src/routes/index.ts

  git add -A
  git commit --quiet -m "feat(users): endpoint GET /users"
  open_pr feat/a-user-endpoint \
    "feat(users): endpoint GET /users" \
    "Adiciona \`GET /users\` e registra a rota no bloco de features de \`src/routes/index.ts\`.

Marcada com \`deploy:dev\`."
fi
ensure_labels feat/a-user-endpoint deploy:dev

# ---------------------------------------------------------------------------
# feat/b-auth-endpoint -- MESMO bloco que A, de proposito
# ---------------------------------------------------------------------------
section "feat/b-auth-endpoint"
if exists feat/b-auth-endpoint; then
  log "ja existe com PR aberto, pulando a criacao (use --reset para recriar)"
else
  git checkout --quiet -B feat/b-auth-endpoint origin/main

  cat > src/routes/auth.ts <<'EOF'
import { Router } from 'express';

export const authRouter = Router();

authRouter.post('/login', (req, res) => {
  const { user } = req.body ?? {};
  res.json({ feature: 'b-auth-endpoint', token: `demo-token-for-${user ?? 'anon'}` });
});
EOF

  cat > test/auth.test.ts <<'EOF'
import request from 'supertest';
import { describe, expect, it } from 'vitest';

import { createApp } from '../src/app';

describe('POST /auth/login', () => {
  it('devolve um token de demonstracao', async () => {
    const res = await request(createApp()).post('/auth/login').send({ user: 'ada' });
    expect(res.status).toBe(200);
    expect(res.body.feature).toBe('b-auth-endpoint');
    expect(res.body.token).toContain('ada');
  });
});
EOF

  # MESMOS marcadores que A. E daqui que sai o conflito da demo.
  insert_before "// feature-imports:end" "import { authRouter } from './auth';" src/routes/index.ts
  insert_before "// feature-routes:end"  "  app.use('/auth', authRouter);"      src/routes/index.ts

  git add -A
  git commit --quiet -m "feat(auth): endpoint POST /auth/login"
  open_pr feat/b-auth-endpoint \
    "feat(auth): endpoint POST /auth/login" \
    "Adiciona \`POST /auth/login\` e registra a rota no bloco de features de \`src/routes/index.ts\`.

Registra no **mesmo ponto** que #1 — as duas branches conflitam. Sem label no seed:
a label \`deploy:hom\` e aplicada ao vivo no bloco 3 da demo."
fi
ensure_labels feat/b-auth-endpoint

# ---------------------------------------------------------------------------
# feat/c-metrics-endpoint -- outra regiao do mesmo arquivo
# ---------------------------------------------------------------------------
section "feat/c-metrics-endpoint"
if exists feat/c-metrics-endpoint; then
  log "ja existe com PR aberto, pulando a criacao (use --reset para recriar)"
else
  git checkout --quiet -B feat/c-metrics-endpoint origin/main

  cat > src/routes/metrics.ts <<'EOF'
import { Router } from 'express';

export const metricsRouter = Router();

const startedAt = Date.now();

metricsRouter.get('/', (_req, res) => {
  res.json({
    feature: 'c-metrics-endpoint',
    uptimeMs: Date.now() - startedAt,
    memoryMb: Math.round(process.memoryUsage().rss / 1024 / 1024),
  });
});
EOF

  cat > test/metrics.test.ts <<'EOF'
import request from 'supertest';
import { describe, expect, it } from 'vitest';

import { createApp } from '../src/app';

describe('GET /metrics', () => {
  it('expoe uptime e memoria', async () => {
    const res = await request(createApp()).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.body.feature).toBe('c-metrics-endpoint');
    expect(typeof res.body.uptimeMs).toBe('number');
  });
});
EOF

  # Regiao SEPARADA. Mesmo arquivo que A e B, hunk diferente, zero conflito.
  insert_before "// observability-imports:end" "import { metricsRouter } from './metrics';" src/routes/index.ts
  insert_before "// observability-routes:end"  "  app.use('/metrics', metricsRouter);"      src/routes/index.ts

  git add -A
  git commit --quiet -m "feat(metrics): endpoint GET /metrics"
  open_pr feat/c-metrics-endpoint \
    "feat(metrics): endpoint GET /metrics" \
    "Adiciona \`GET /metrics\` e registra no bloco de observabilidade de \`src/routes/index.ts\`.

Mesmo arquivo que #1 e #2, **outra regiao**: nao conflita com ninguem.
Marcada com \`deploy:dev\`."
fi
ensure_labels feat/c-metrics-endpoint deploy:dev

git checkout --quiet "$ORIGINAL_BRANCH"

# ---------------------------------------------------------------------------
# Primeira reconstrucao: as branches de ambiente passam a existir e a Vercel
# ganha uma URL para cada uma. Sem isso o bloco 1 da demo abre um 404.
# ---------------------------------------------------------------------------
section "Primeira reconstrucao"
if gh workflow run rebuild-env.yml -f environment=ambos >/dev/null 2>&1; then
  log "rebuild-env disparado (dev = main + a + c, hom = main)"
  log "acompanhe: gh run watch"
else
  echo "  Nao consegui disparar rebuild-env." >&2
  echo "  Normal se o workflow ainda nao esta na main. Faca push da main e rode:" >&2
  echo "    gh workflow run rebuild-env.yml -f environment=ambos" >&2
fi

section "Estado da demo"
gh pr list --state open --base main --json number,title,headRefName,labels \
  --jq '.[] | "  #\(.number)  \(.headRefName)  [\(.labels | map(.name) | join(", "))]"'
echo
echo "  dev esperado: main + feat/a-user-endpoint + feat/c-metrics-endpoint"
echo "  hom esperado: main (vazia -- voce monta ao vivo no bloco 2)"
