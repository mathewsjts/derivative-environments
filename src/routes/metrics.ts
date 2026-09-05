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
