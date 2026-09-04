import express, { type Express } from 'express';

import { loadManifest, summarize } from './manifest';
import { registerRoutes } from './routes';

export function createApp(): Express {
  const app = express();

  app.disable('x-powered-by');
  app.use(express.json());

  // Raiz existe so para a demo: abrir a URL da Vercel e ja ver o conjunto,
  // sem ter que digitar /version na barra de endereco no meio da apresentacao.
  app.get('/', (_req, res) => {
    const manifest = loadManifest();
    res.json({
      service: 'derivative-environments',
      environment: manifest.environment,
      summary: summarize(manifest),
      routes: ['/health', '/version'],
    });
  });

  registerRoutes(app);

  return app;
}
