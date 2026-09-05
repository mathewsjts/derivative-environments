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

section "Labels"
./scripts/create-labels.sh >/dev/null
log "deploy:dev deploy:hom priority:high blocked:dev blocked:hom"

# ---------------------------------------------------------------------------
# --reset: derruba tudo para poder ensaiar a demo quantas vezes quiser.
# ---------------------------------------------------------------------------
if [ "$RESET" = true ]; then
  section "Reset"
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
