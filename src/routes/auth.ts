import { Router } from 'express';

export const authRouter = Router();

authRouter.post('/login', (req, res) => {
  const { user } = req.body ?? {};
  res.json({ feature: 'b-auth-endpoint', token: `demo-token-for-${user ?? 'anon'}` });
});
