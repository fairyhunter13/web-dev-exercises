import { defineConfig } from 'vitest/config';

// Coverage is a floor, not the goal: every test in test/ was written to defend
// a claim the source makes, and the percentage is what falls out of that. CI
// fails under 80% so the floor cannot quietly drop.
export default defineConfig({
  test: {
    coverage: {
      provider: 'v8',
      include: ['src/**/*.js'],
      reporter: ['text', 'text-summary'],
      thresholds: { lines: 80, functions: 80, branches: 80, statements: 80 },
    },
  },
});
