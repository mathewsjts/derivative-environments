import request from 'supertest';
import { describe, expect, it } from 'vitest';

import { createApp } from '../src/app';
import { resolvedFeatures, summarize, type BuildManifest } from '../src/manifest';

const app = createApp();

describe('GET /version', () => {
  it('expoe ambiente, base e o conjunto de features', async () => {
    const res = await request(app).get('/version');

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('environment');
    expect(res.body).toHaveProperty('base.branch');
    expect(res.body).toHaveProperty('previousEnvHead');
    expect(res.body).toHaveProperty('summary');
    expect(Array.isArray(res.body.features)).toBe(true);
    expect(Array.isArray(res.body.excluded)).toBe(true);
    expect(res.body.featureCount).toBe(res.body.features.length);
  });

  it('na main o conjunto e vazio', async () => {
    const res = await request(app).get('/version');
    expect(res.body.environment).toBe('main');
    expect(res.body.features).toEqual([]);
  });
});

describe('summarize', () => {
  it('monta a linha que a plateia le no browser', () => {
    const manifest: BuildManifest = {
      environment: 'hom',
      base: { branch: 'main', sha: 'abc1234' },
      previousEnvHead: 'deadbee',
      features: [
        { pr: 1, branch: 'feat/a-user-endpoint', sha: 'aaa', author: 'x' },
        { pr: 3, branch: 'feat/c-metrics-endpoint', sha: 'ccc', author: 'y' },
      ],
      excluded: [],
    };

    expect(summarize(manifest)).toBe(
      'main + feat/a-user-endpoint + feat/c-metrics-endpoint',
    );
  });

  it('sem features, e so a base', () => {
    expect(
      summarize({
        environment: 'dev',
        base: { branch: 'main', sha: 'abc' },
        previousEnvHead: null,
        features: [],
        excluded: [],
      }),
    ).toBe('main');
  });
});

describe('resolvedFeatures', () => {
  const base = {
    environment: 'hom',
    base: { branch: 'main', sha: 'abc' },
    previousEnvHead: null,
    excluded: [],
  };

  it('separa quem so esta no ar por uma resolucao gravada', () => {
    const manifest: BuildManifest = {
      ...base,
      resolutions: { ref: 'env-resolutions', sha: 'deadbee' },
      features: [
        { pr: 1, branch: 'feat/a-user-endpoint', sha: 'aaa', author: 'x' },
        {
          pr: 2,
          branch: 'feat/b-auth-endpoint',
          sha: 'bbb',
          author: 'y',
          resolvedBy: ['src/routes/index.ts'],
          conflictsWith: 1,
        },
      ],
    };

    expect(resolvedFeatures(manifest).map((f) => f.pr)).toEqual([2]);
  });

  it('um conjunto sem resolucao nenhuma devolve lista vazia', () => {
    const manifest: BuildManifest = {
      ...base,
      features: [{ pr: 1, branch: 'feat/a-user-endpoint', sha: 'aaa', author: 'x' }],
    };

    expect(resolvedFeatures(manifest)).toEqual([]);
    // A ausencia da chave e o que mantem o descritor do ambiente estavel.
    expect(manifest.resolutions).toBeUndefined();
  });
});
