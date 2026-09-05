import { Router } from 'express';

import { loadManifest, resolvedFeatures, summarize } from '../manifest';

export const versionRouter = Router();

/**
 * GET /version -- o coracao da demo.
 *
 * Responde SHA, branch de ambiente e o conjunto de features presentes neste
 * build. Tambem responde o que ficou de FORA e por que: sem isso a plateia ve
 * uma ausencia e tem que acreditar na explicacao; com isso ela le o motivo no
 * proprio browser.
 */
versionRouter.get('/', (_req, res) => {
  const manifest = loadManifest();

  res.json({
    environment: manifest.environment,
    // Na Vercel essas duas variaveis existem em runtime. Fora dela, caimos no
    // que o manifesto registrou no momento da montagem.
    branch: process.env.VERCEL_GIT_COMMIT_REF ?? manifest.environment,
    commit: process.env.VERCEL_GIT_COMMIT_SHA ?? null,
    base: manifest.base,
    previousEnvHead: manifest.previousEnvHead,
    summary: summarize(manifest),
    featureCount: manifest.features.length,
    features: manifest.features,
    excluded: manifest.excluded,
    // De onde saiu o codigo que nao esta em nenhum PR. Sem isso, uma feature
    // que so esta no ar por causa de uma resolucao gravada parece igual a
    // qualquer outra -- e a plateia nao tem como saber que aquele merge foi
    // escrito por alguem e nao pelo git.
    resolutions: manifest.resolutions ?? null,
    resolvedCount: resolvedFeatures(manifest).length,
  });
});
