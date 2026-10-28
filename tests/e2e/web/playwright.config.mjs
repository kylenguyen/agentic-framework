// tests/e2e/web/playwright.config.mjs: the browser e2e suite for the web dashboard, run by tests/e2e/web.sh
// inside its container against the server fixture.sh supervises. One worker: every spec shares one tmux server
// and one web server (which a spec restarts), so nothing runs in parallel. T7 adds the phone projects here.
import { defineConfig, devices } from '@playwright/test';
import { BASE, LOGIN } from './helpers.mjs';

const OUT = process.env.WEB_E2E_OUT ?? '/work/results';

export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.mjs',
  workers: 1,
  fullyParallel: false,
  retries: 0,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  outputDir: OUT,
  reporter: [['list'], ['json', { outputFile: `${OUT}/results.json` }]],
  use: {
    baseURL: BASE,
    // What tailscale serve adds in front of the real server.
    extraHTTPHeaders: { 'Tailscale-User-Login': LOGIN },
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'desktop-chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 } } },
    { name: 'desktop-webkit', use: { ...devices['Desktop Safari'], viewport: { width: 1440, height: 900 } } },
  ],
});
