// tests/e2e/web/sim.spec.mjs: the Devices panel (docs/web-dashboard-plan.md T9) in Chromium and WebKit. A
// stand-in `sim` in ~/bin, first on the server's PATH, prints the captured status (tests/web/fixtures/
// sim-status.json: three Android and two web slots); without it the panel is hidden. The server looks sim up per
// request, so writing or removing the file is enough. The stand-in is removed after the spec, so other specs see a
// host without the simulator service.
import { test, expect } from '@playwright/test';
import { rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { home } from './helpers.mjs';

const FIXTURE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../web/fixtures/sim-status.json');
const STUB = path.join(home, 'bin/sim');
const standIn = (body) => writeFileSync(STUB, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
const withSim = () => standIn(`cat '${FIXTURE}'`);
const noSim = () => rmSync(STUB, { force: true });
const panel = (page) => page.locator('#sim-panel');
const slot = (page, platform, n) => page.locator(`.sim-slot[data-platform="${platform}"][data-slot="${n}"]`);

test.afterAll(noSim);

test('the panel shows five slots in two platform groups', async ({ page }) => {
  withSim();
  await page.goto('/?test=1');
  await expect(panel(page)).toBeVisible();
  await expect(panel(page).locator('summary h2')).toHaveText('Devices');
  await expect(panel(page).locator('summary .count')).toHaveText('5');
  await expect(page.locator('.sim-group')).toHaveCount(2);
  await expect(page.locator('.sim-group-title')).toHaveText([/^Android\s*3$/, /^Web\s*2$/]);
  await expect(page.locator('.sim-slot')).toHaveCount(5);
  await expect(page.locator('.sim-group[data-platform="android"] .sim-slot')).toHaveCount(3);
  await expect(page.locator('.sim-group[data-platform="web"] .sim-slot')).toHaveCount(2);

  const a1 = slot(page, 'android', 1);
  await expect(a1.locator('.sim-device')).toHaveText('emulator-5600');
  await expect(a1.locator('.sim-state')).toHaveText('active');
  await expect(a1.locator('.sim-lease')).toHaveText('login-fix');
  await expect(a1.locator('.sim-idle')).toHaveText('idle 1m');
  await expect(slot(page, 'android', 2).locator('.sim-lease')).toHaveText('shop');
  await expect(slot(page, 'android', 2).locator('.sim-idle')).toHaveText('idle 25m');
  await expect(slot(page, 'android', 3).locator('.sim-lease')).toHaveText('free');
  await expect(slot(page, 'android', 3).locator('.sim-idle')).toHaveText('unused');
  await expect(slot(page, 'android', 3).locator('.sim-state')).toHaveText('inactive');
  await expect(slot(page, 'web', 1).locator('.sim-device')).toHaveText('Web slot 1');
  await expect(slot(page, 'web', 1).locator('.sim-state')).toHaveCount(0);
  await expect(slot(page, 'web', 1).locator('.sim-lease')).toHaveText('checkout');
  await expect(slot(page, 'web', 1).locator('.sim-idle')).toHaveText('used just now');
  await expect(slot(page, 'web', 2).locator('.sim-idle')).toHaveText('idle 6d');
  await expect(page.locator('.sim-tunnel')).toHaveCount(0);
  expect(await page.evaluate(() => window.__csp)).toEqual([]);

  // Collapsible, and it stays collapsed across a reload.
  await panel(page).locator('summary').click();
  await expect(page.locator('.sim-groups')).toBeHidden();
  expect(await page.evaluate(() => localStorage.getItem('agent-web.sim-open'))).toBe('0');
  await page.reload();
  await expect(panel(page)).toBeVisible();
  await expect(panel(page)).not.toHaveAttribute('open');
  await panel(page).locator('summary').click();
  await expect(page.locator('.sim-groups')).toBeVisible();
});

test('an iOS slot shows its tunnel ports', async ({ page }) => {
  standIn(`jq '. + [{platform: "ios", slot: 1, device: "agent-ios-1", state: "booted", idle_secs: 7300,
    lease: null, tunnel: [8081, 19000]}]' '${FIXTURE}'`);
  await page.goto('/?test=1');
  await expect(page.locator('.sim-group')).toHaveCount(3);
  const i1 = slot(page, 'ios', 1);
  await expect(i1.locator('.sim-tunnel')).toHaveText('tunnel 8081, 19000');
  await expect(i1.locator('.sim-idle')).toHaveText('idle 2h');
  await expect(page.locator('.sim-group-title').nth(2)).toHaveText(/^iOS/);
});

test('the panel is hidden without sim, and goes when sim does', async ({ page }) => {
  noSim();
  const answered = page.waitForResponse((r) => r.url().endsWith('/api/sim'));
  await page.goto('/?test=1');
  expect(await (await answered).json()).toEqual({ available: false });
  await expect(panel(page)).toHaveCount(0);
  await expect(page.locator('#list-panels')).toBeHidden();

  withSim();
  await expect(panel(page)).toBeVisible({ timeout: 15_000 });
  standIn('exit 1');
  await expect(panel(page)).toHaveCount(0, { timeout: 15_000 });
  await expect(page.locator('#list-panels')).toBeHidden();
});

test('no polling while a terminal is open', async ({ page }) => {
  withSim();
  await page.goto('/?test=1');
  await expect(panel(page)).toBeVisible();
  let calls = 0;
  page.on('request', (r) => { if (r.url().endsWith('/api/sim')) calls += 1; });
  await page.goto('/?test=1#/s/demo');
  await expect(page.locator('#term-name')).toHaveText('demo');
  await page.waitForTimeout(11_500);
  expect(calls).toBe(0);
  await page.locator('#back').click();
  await expect(panel(page)).toBeVisible();
  expect(calls).toBeGreaterThan(0);
});

test('the panel fits a 390 px wide phone', async ({ page }) => {
  withSim();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/?test=1');
  await expect(page.locator('.sim-slot')).toHaveCount(5);
  const box = await panel(page).boundingBox();
  expect(box.x).toBeGreaterThanOrEqual(0);
  expect(box.x + box.width).toBeLessThanOrEqual(390);
  const overflow = await page.evaluate(() => [...document.querySelectorAll('#sim-panel, #sim-panel *')]
    .filter((e) => e.scrollWidth > e.clientWidth + 1 || e.getBoundingClientRect().right > 390)
    .map((e) => e.className || e.tagName));
  expect(overflow).toEqual([]);
});
