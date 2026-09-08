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
