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
