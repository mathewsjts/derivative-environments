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
