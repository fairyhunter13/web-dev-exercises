import { fileURLToPath, URL } from 'node:url'
// vitest/config re-exports Vite's defineConfig with the `test` key typed.
import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  test: {
    environment: 'jsdom',
    // Playwright specs live in e2e/ and are run by `npm run test:e2e`. Without
    // this, vitest picks them up and fails on the missing Playwright runner.
    include: ['src/**/*.spec.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.{ts,vue}'],
      // main.ts is five lines that mount the app, and it is covered by the
      // Playwright suite, which loads the real page.
      exclude: ['src/main.ts'],
      reporter: ['text', 'text-summary'],
      thresholds: { lines: 80, functions: 80, branches: 80, statements: 80 },
    },
  },
})
