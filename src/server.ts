import { createApp } from './app';

// Entrypoint local e do container. Na Vercel quem serve e api/index.ts:
// serverless nao roda um processo que faz listen.
const port = Number(process.env.PORT ?? 3000);

createApp().listen(port, () => {
  console.log(`derivative-environments ouvindo em http://localhost:${port}`);
});
