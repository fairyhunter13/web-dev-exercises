import { defineConfig, devices } from '@playwright/test'

/**
 * The two web servers are started by Playwright itself, so `npm run test:e2e`
 * is the whole command. Nothing to start by hand and nothing to leave running
 * afterwards. `reuseExistingServer` keeps a local dev loop fast while still
 * starting clean in CI.
 */
// Point the suite at the deployed stack instead of localhost:
//
//   E2E_BASE_URL=https://d3irwxh641u3pi.cloudfront.net npm run test:e2e
//
// The same assertions then run against real CloudFront, real API Gateway and
// real Lambda, which is the only way to prove the deploy works rather than
// prove the local server does. Starting the local servers would be pointless in
// that case, so webServer is dropped when the variable is set.
const deployedURL = process.env.E2E_BASE_URL

export default defineConfig({
  testDir: './e2e',
  // capture-demo.spec.ts is a screenshot recorder, not a test, and is run
  // separately via `npm run capture`. Excluding it here rather than by naming
  // convention keeps `npm run test:e2e` reporting only real assertions.
  testIgnore: '**/capture-demo.spec.ts',
  fullyParallel: true,
  // One worker against the deployed stack. The live WebSocket stage is
  // throttled to 5 requests a second, which is sized for a reviewer with two
  // windows open, not for four tests connecting and typing at once. Parallel
  // workers trip that limit and the failure looks like a flaky app rather than
  // the cost control it is. Locally there is no throttle, so the suite stays
  // parallel there.
  workers: deployedURL ? 1 : undefined,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  use: {
    baseURL: deployedURL ?? 'http://localhost:5173',
    trace: 'on-first-retry',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: deployedURL
    ? undefined
    : [
        {
          command: 'go run ./cmd/localserver',
          cwd: '../backend',
          url: 'http://localhost:8080/healthz',
          reuseExistingServer: !process.env.CI,
          stdout: 'pipe',
        },
        {
          command: 'npm run dev',
          url: 'http://localhost:5173',
          reuseExistingServer: !process.env.CI,
        },
      ],
})
