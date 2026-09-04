# syntax=docker/dockerfile:1
#
# GATE DE CI, NAO MECANISMO DE DEPLOY.
#
# A Vercel nao usa este arquivo -- ela roda a API como funcao serverless a
# partir de api/index.ts. O `docker build` existe para provar, antes da main e
# antes de qualquer ambiente derivado, que o CONJUNTO montado compila e instala
# com dependencias de producao. Se ele falha na reconstrucao de dev/hom, o job
# nao publica e o ambiente anterior continua no ar.
#
# Orcamento: build limpo (sem cache) abaixo de 30s.

# ---------------------------------------------------------------------------
# Estagio 1 -- dependencias de producao
# ---------------------------------------------------------------------------
FROM node:20-alpine AS prod-deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

# ---------------------------------------------------------------------------
# Estagio 2 -- compilacao
#
# Parte das deps de producao e acrescenta SO o typescript. Instalar o
# devDependencies inteiro aqui (vitest, eslint, vite) custaria ~20s e nada
# disso participa da compilacao -- lint e teste sao jobs proprios do CI.
# ---------------------------------------------------------------------------
FROM prod-deps AS builder
RUN npm install --no-save --no-audit --no-fund typescript@5.9.3
COPY tsconfig.json build-manifest.json ./
COPY src ./src
RUN npx tsc -p tsconfig.json

# ---------------------------------------------------------------------------
# Estagio 3 -- runtime
#
# node_modules vem do estagio prod-deps, que rodou `npm ci --omit=dev`: a
# imagem final carrega exatamente as deps de producao, sem repetir a instalacao.
# ---------------------------------------------------------------------------
FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3000

COPY --from=prod-deps /app/node_modules ./node_modules
COPY package.json build-manifest.json ./
COPY --from=builder /app/dist ./dist

USER node
EXPOSE 3000
CMD ["node", "dist/src/server.js"]
