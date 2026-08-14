import { defineConfig } from '@playwright/test'
import base from './playwright.config'

/**
 * The screenshot recorder, run with `npm run capture`.
 *
 * It lives in its own config because Playwright runs every project in a
 * config, so an opt-in project in the main file would join the default run.
 */
export default defineConfig({
  ...base,
  testIgnore: undefined,
  testMatch: '**/capture-demo.spec.ts',
})
