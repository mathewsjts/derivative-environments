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
