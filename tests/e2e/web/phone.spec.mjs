// tests/e2e/web/phone.spec.mjs: the phone layout (docs/web-dashboard-plan.md T7) on the phone-iphone (WebKit,
// iPhone 15) and phone-android (Chromium, Pixel 7) projects: no sideways scroll at 390 px, the soft keys and
// their sticky Ctrl reaching the pane, the line box, the font size, the manifest and the service worker. Taps
// are real touch taps (the device profiles have touch), so a key that stole focus from the terminal would show.
// SHOTS=1 (web.sh SHOTS=<dir>) adds 390x844 screenshots of the list and the terminal in both themes.
import { test, expect } from '@playwright/test';
import { mkdirSync } from 'node:fs';
import { agent, newShell, sessions, tag, termText } from './helpers.mjs';

const VIEW = { width: 390, height: 844 };
const key = (page, k) => page.locator(`#term-footer .key[data-key="${k}"]`);
const prompt = (page) => expect.poll(() => termText(page), { timeout: 15_000 }).toMatch(/\$ ?$/m);
const noSideScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
const termFocused = (page) => page.evaluate(() => document.activeElement?.classList.contains('xterm-helper-textarea'));
// Lines that are exactly `text`: the output, not the echo of the command that printed it.
const outputLines = async (page, text) => (await termText(page)).split('\n').filter((l) => l.trimEnd() === text).length;

async function typeLine(page, cmd) {
  await page.keyboard.type(cmd);
  await page.keyboard.press('Enter');
}

test.describe('the terminal on a phone', () => {
  test.describe.configure({ mode: 'serial' });
  let name;

  test.beforeAll(({}, testInfo) => {
    name = newShell(`ph-${tag(testInfo)}`);
  });
  test.afterAll(() => {
    if (sessions().some((s) => s.name === name)) agent('kill', name, '--force');
  });

  async function open(page) {
    await page.setViewportSize(VIEW);
    await page.goto(`/?test=1#/s/${encodeURIComponent(name)}`);
    await expect(page.locator('#term-state')).toHaveText('running');
    await prompt(page);
    await page.locator('#term').tap();
  }

  test('the key bar shows under 700 px only, and nothing scrolls sideways', async ({ page }) => {
    await open(page);
    await expect(page.locator('#term-footer .phone-keys')).toBeVisible();
    expect(await noSideScroll(page)).toBe(true);
    // The bar sits inside the window, under the terminal.
    const bar = await page.locator('#term-footer').boundingBox();
    const term = await page.locator('#term').boundingBox();
    expect(bar.y).toBeGreaterThanOrEqual(term.y + term.height - 1);
    expect(bar.y + bar.height).toBeLessThanOrEqual(VIEW.height + 1);
    await page.setViewportSize({ width: 1024, height: 768 });
    await expect(page.locator('#term-footer .phone-keys')).toHaveCount(0);
    await expect(page.locator('#term-footer')).toBeHidden();
    await page.setViewportSize(VIEW);
    await expect(page.locator('#term-footer .phone-keys')).toBeVisible();
    expect(await page.evaluate(() => window.__csp)).toEqual([]);
  });

  test('Ctrl then a typed c interrupts sleep 30, and keys leave the focus in the terminal', async ({ page }) => {
    await open(page);
    await typeLine(page, 'sleep 30');
    await key(page, 'ctrl').tap();
    await expect(key(page, 'ctrl')).toHaveAttribute('aria-pressed', 'true');
    expect(await termFocused(page)).toBe(true);
    await page.keyboard.press('c');
    await expect(key(page, 'ctrl')).toHaveAttribute('aria-pressed', 'false');
    // Typed ahead, this line only prints once sleep is gone: well inside 30 s means the ^C reached it.
    await typeLine(page, 'echo int-ok');
    await expect.poll(() => outputLines(page, 'int-ok'), { timeout: 8_000 }).toBe(1);
  });

  test('Esc reaches the pane, and ^C ends cat', async ({ page }) => {
    await open(page);
    // The tty echoes ESC as ^[ too, so cat's own line is the one sed marks.
    await typeLine(page, "cat -v | sed -u 's/^/got:/'");
    await key(page, 'esc').tap();
    await page.keyboard.press('Enter');
    await expect.poll(() => outputLines(page, 'got:^[')).toBe(1);
    await key(page, 'ctrl-c').tap();
    await typeLine(page, 'echo cat-done');
    await expect.poll(() => outputLines(page, 'cat-done'), { timeout: 8_000 }).toBe(1);
  });

  test('the arrow keys recall history', async ({ page }) => {
    await open(page);
    // dash, the container's /bin/sh, has no line editing; bash does.
    await typeLine(page, 'exec bash --norc --noprofile');
    await prompt(page);
    await typeLine(page, 'echo hist-1');
    await typeLine(page, 'echo hist-2');
    await expect.poll(() => outputLines(page, 'hist-2')).toBe(1);
    await key(page, 'up').tap();
    await key(page, 'up').tap();
    await key(page, 'down').tap();
    await key(page, 'up').tap();
    await page.keyboard.press('Enter');
    await expect.poll(() => outputLines(page, 'hist-1')).toBe(2);
    expect(await outputLines(page, 'hist-2')).toBe(1);
  });

  test('line mode sends the box with Enter, and stays on after a reload', async ({ page }) => {
    await open(page);
    await key(page, 'line').tap();
    const input = page.locator('#term-footer .phone-line-input');
    await expect(input).toBeVisible();
    await expect(input).toBeFocused();
    await input.fill('echo phone-ok');
    await input.press('Enter');
    await expect.poll(() => outputLines(page, 'phone-ok')).toBe(1);
    await expect(input).toHaveValue('');
    await expect(input).toBeFocused();
    await page.reload();
    await prompt(page);
    await expect(page.locator('#term-footer .phone-line-input')).toBeVisible();
    await key(page, 'line').tap();
    await expect(page.locator('#term-footer .phone-line')).toBeHidden();
    expect(await termFocused(page)).toBe(true);
  });

  test('the font size steps between 12 and 18 px and is remembered', async ({ page }) => {
    await open(page);
    const size = () => page.evaluate(() => window.__term.options.fontSize);
    const start = await size();
    await key(page, 'font-up').tap();
    expect(await size()).toBe(start + 1);
    for (let i = 0; i < 8; i++) await key(page, 'font-up').tap();
    expect(await size()).toBe(18);
    await page.reload();
    await prompt(page);
    expect(await size()).toBe(18);
    for (let i = 0; i < 8; i++) await key(page, 'font-down').tap();
    expect(await size()).toBe(12);
    expect(await noSideScroll(page)).toBe(true);
    await page.evaluate(() => localStorage.clear());
  });
});

test('the list is single cards within 390 px', async ({ page }) => {
  await page.setViewportSize(VIEW);
  await page.goto('/?test=1');
  const card = page.locator('#sessions li[data-name="demo"]');
  await expect(card).toBeVisible();
  await expect(card.locator('.state-label')).toBeVisible();
  await expect(card.locator('.age')).toBeVisible();
  const box = await card.boundingBox();
  expect(box.x + box.width).toBeLessThanOrEqual(VIEW.width);
  expect(await noSideScroll(page)).toBe(true);
});

test('the manifest is valid JSON whose icons resolve', async ({ page, request }) => {
  await page.goto('/');
  const href = await page.locator('link[rel="manifest"]').getAttribute('href');
  await expect(page.locator('meta[name="apple-mobile-web-app-capable"]')).toHaveAttribute('content', 'yes');
  const res = await request.get(href);
  expect(res.status()).toBe(200);
  expect(res.headers()['content-type']).toMatch(/^application\/manifest\+json/);
  const manifest = JSON.parse(await res.text());
  expect(manifest.display).toBe('standalone');
  expect(manifest.start_url).toBe('/');
  const sizes = manifest.icons.map((i) => i.sizes);
  expect(sizes).toContain('192x192');
  expect(sizes).toContain('512x512');
  for (const icon of manifest.icons) {
    const r = await request.get(new URL(icon.src, res.url()).href);
    expect(r.status(), icon.src).toBe(200);
    expect(r.headers()['content-type']).toBe('image/png');
  }
  const touch = await page.locator('link[rel="apple-touch-icon"]').getAttribute('href');
  expect((await request.get(touch)).status()).toBe(200);
});

test('the service worker registers', async ({ page, context }) => {
  // Chromium fetches the worker script without Playwright's extraHTTPHeaders, so the server would refuse it
  // with 403; tailscale serve adds the login to every request, this route does the same for the one it misses.
  await context.route('**/sw.js', async (r) => r.fulfill({ response: await r.fetch() }));
  await page.goto('/');
  const script = await page.evaluate(async () => (await navigator.serviceWorker.ready).active.scriptURL);
  expect(new URL(script).pathname).toBe('/sw.js');
  // It must not answer /api/ from a cache: the session list still changes under it.
  const fresh = await page.evaluate(async () => (await fetch('/api/health', { cache: 'no-store' })).ok);
  expect(fresh).toBe(true);
});

// The design pass at the size the plan names, as files to look at. web.sh copies /work/shots out to $SHOTS.
test.describe('screenshots', () => {
  test.skip(() => !process.env.SHOTS, 'SHOTS=1');
  const dir = '/work/shots';
  for (const scheme of ['light', 'dark']) {
    test(`list and terminal at 390x844, ${scheme}`, async ({ page }, testInfo) => {
      mkdirSync(dir, { recursive: true });
      const shot = (what) => page.screenshot({ path: `${dir}/${testInfo.project.name}-${what}-390x844-${scheme}.png` });
      const slug = `phshot-${tag(testInfo)}`;
      const name = sessions().find((s) => s.name === `demo-${slug}`)?.name ?? newShell(slug);
      await page.setViewportSize(VIEW);
      await page.emulateMedia({ colorScheme: scheme });
      await page.goto('/?test=1');
      await expect(page.locator(`#sessions li[data-name="${name}"]`)).toBeVisible();
      await shot('list');
      await page.goto(`/?test=1#/s/${encodeURIComponent(name)}`);
      await prompt(page);
      await page.locator('#term').tap();
      await typeLine(page, 'clear; ls -la /work/repo | head -12; printf "\\033[1;32mgreen \\033[1;34mblue \\033[0m\\n"');
      await key(page, 'ctrl').tap();
      await page.waitForTimeout(500);
      await shot('term');
      await key(page, 'ctrl').tap();
      await key(page, 'line').tap();
      await page.locator('#term-footer .phone-line-input').fill('git status');
      await shot('term-line');
      await page.evaluate(() => localStorage.clear());
    });
  }
});
