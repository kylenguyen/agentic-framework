// tests/e2e/web/playwright.config.mjs: the browser e2e suite for the web dashboard, run by tests/e2e/web.sh
// inside its container against the server fixture.sh supervises. One worker: every spec shares one tmux server
// and one web server (which a spec restarts), so nothing runs in parallel. The phone projects run phone.spec.mjs
// alone, and the desktop ones everything else: the desktop specs assume a wide window. alerts.spec.mjs runs on
// desktop-chromium only; journey.spec.mjs (the T13 walk-through) runs on both and checks the push in Chromium.
import { defineConfig, devices } from '@playwright/test';
import { BASE, LOGIN } from './helpers.mjs';

const OUT = process.env.WEB_E2E_OUT ?? '/work/results';
const PHONE = 'phone.spec.mjs';
const CHROMIUM_ONLY = 'alerts.spec.mjs';   // Web Push and notification permissions are Chromium's to grant

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
    { name: 'desktop-chromium', testIgnore: PHONE, use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 } } },
    { name: 'desktop-webkit', testIgnore: [PHONE, CHROMIUM_ONLY], use: { ...devices['Desktop Safari'], viewport: { width: 1440, height: 900 } } },
    { name: 'phone-iphone', testMatch: PHONE, use: { ...devices['iPhone 15'] } },
    { name: 'phone-android', testMatch: PHONE, use: { ...devices['Pixel 7'] } },
  ],
});
