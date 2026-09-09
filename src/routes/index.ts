import type { Express } from 'express';

import { healthRouter } from './health';
import { versionRouter } from './version';

// ===========================================================================
// BLOCO 1 -- IMPORTS DE FEATURE
//
// Toda feature "de produto" registra seu import entre os dois marcadores
// abaixo, imediatamente ANTES do `:end`. Duas features fazem a insercao no
// mesmo anchor -- e por isso que o conflito entre elas e deterministico, e
// nao um acidente de formatacao.
//
// Nao ordene, nao reorganize: o objetivo aqui e reproduzir o registry central
// que todo app Express/Nest/Fastify de verdade tem.
// ===========================================================================
// feature-imports:start
import { authRouter } from './auth';
// feature-imports:end

// ===========================================================================
// BLOCO 2 -- IMPORTS DE OBSERVABILIDADE
//
// Regiao separada da de cima por um bloco de linhas inalteradas. O algoritmo
// de merge do git usa 3 linhas de contexto: blocos vizinhos demais colapsam
// num conflito so. Com a distancia abaixo, uma feature que registra AQUI
// convive sem conflito com uma feature que registra no BLOCO 1 -- mesmo
// arquivo, hunks diferentes.
//
// E o contra-exemplo que a demo precisa: a exclusao e por regiao, nao por
// arquivo. "Todo mundo mexe no mesmo arquivo" nao trava o ambiente.
// ===========================================================================
// observability-imports:start
// observability-imports:end

export function registerRoutes(app: Express): void {
  app.use('/health', healthRouter);
  app.use('/version', versionRouter);

  // feature-routes:start
  app.use('/auth', authRouter);
  // feature-routes:end

  // -------------------------------------------------------------------------
  // A distancia entre os dois blocos de registro e proposital, pelo mesmo
  // motivo dos imports: manter os hunks separados para o git.
  // -------------------------------------------------------------------------

  // observability-routes:start
  // observability-routes:end
}
