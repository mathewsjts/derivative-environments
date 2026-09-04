// Entrypoint serverless da Vercel.
//
// A Vercel NAO usa o Dockerfile deste repo -- ela detecta api/index.ts como
// funcao e a executa. O Dockerfile existe como gate de CI (ver DEMO.md e
// SETUP.md). Um app Express e, na pratica, um handler (req, res), que e
// exatamente o que a Vercel espera aqui.
import { createApp } from '../src/app';

export default createApp();
