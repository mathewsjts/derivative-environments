import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    include: ['test/**/*.test.ts'],
    // A POC precisa de CI curto: sem coverage por padrao, sem watch.
    reporters: ['default'],
  },
});
