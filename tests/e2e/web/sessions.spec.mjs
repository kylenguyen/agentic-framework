// tests/e2e/web/sessions.spec.mjs: the desktop dashboard (docs/web-dashboard-plan.md T6) in Chromium and WebKit:
// the list, New into a terminal, the web device, a server restart under an open terminal, both kill dialogs, a
// session that is gone, and the 403 page. Each project makes its own sessions (tag()), since both run against
// the one host the container holds. SHOTS=1 (web.sh SHOTS=<dir>) adds the screenshot pass, Chromium only.
import { test, expect } from '@playwright/test';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { agent, newShell, restartServer, sessions, tag, termText, workspace } from './helpers.mjs';

const card = (page, name) => page.locator(`#sessions li[data-name="${name}"]`);
const prompt = (page) => expect.poll(() => termText(page), { timeout: 15_000 }).toMatch(/\$ ?$/m);
async function run(page, cmd) {
  await page.locator('#term').click();
  await page.keyboard.type(cmd);
  await page.keyboard.press('Enter');
}

test('the list shows the session the fixture made', async ({ page }) => {
  await page.goto('/?test=1');
  const c = card(page, 'demo');
  await expect(c).toBeVisible();
  await expect(c.locator('.name')).toHaveText('demo');
  await expect(c.locator('.harness')).toHaveText('Claude');
  await expect(c.locator('.repo')).toHaveText('demo');
  await expect(c.locator('.branch')).toHaveText('main');
  await expect(c.locator('.badge.attention')).toHaveAttribute('data-attention', '');
  await expect(page).toHaveTitle('Agents');
});

test.describe('a shell session made with New', () => {
  test.describe.configure({ mode: 'serial' });
  let page;
  let name;

  test.beforeAll(async ({ browser }) => {
    page = await browser.newPage();
  });
  test.afterAll(async () => {
    await page?.close();
  });

  test('New with harness shell lands on the terminal, which runs what is typed', async ({}, testInfo) => {
    const slug = `e2e-${tag(testInfo)}`;
    await page.goto('/?test=1');
    await page.locator('#new-btn').click();
    await expect(page.locator('#new-dialog')).toBeVisible();
    await expect(page.locator('#new-harness')).toHaveValue('claude');
    await expect(page.locator('#new-repo')).toHaveValue('demo');
    await page.locator('#new-harness').selectOption('shell');
    await page.locator('#new-slug').fill(slug);
    await page.locator('#new-create').click();
    await expect(page).toHaveURL(/#\/s\/demo-e2e-/);
    name = decodeURIComponent(new URL(page.url()).hash.slice(4));
    await expect(page).toHaveTitle(name);
    await expect(page.locator('#term-name')).toHaveText(name);
    await expect(page.locator('#term-state')).toHaveText('running');
    await prompt(page);
    await run(page, 'echo e2e-ok');
    await expect.poll(() => termText(page)).toMatch(/^e2e-ok\s*$/m);
    // Truecolor cells are styled through the CSSOM bridge in app.mjs; nothing may trip the CSP.
    await run(page, "printf '\\033[38;2;255;0;0mTRUERED\\033[0m\\n'");
    const red = page.locator('.xterm-rows span', { hasText: /^TRUERED$/ });
    await expect(red).toHaveCSS('color', 'rgb(255, 0, 0)');
    await expect(page.locator('.xterm-viewport')).toHaveCSS('background-color', 'rgb(13, 17, 23)');
    expect(await page.evaluate(() => window.__csp)).toEqual([]);
    expect(sessions().find((s) => s.name === name)?.devices).toEqual(['web']);
  });

  test('the list shows the session with device web while its terminal is open, and Back closes it', async ({ context }) => {
    const other = await context.newPage();
    await other.goto('/?test=1');
    await expect(card(other, name).locator('.device')).toHaveText(['web']);
    await page.locator('#back').click();
    await expect(page).toHaveURL(/#\/$/);
    await expect(card(page, name)).toBeVisible();
    await expect(card(page, name).locator('.device')).toHaveText(['detached'], { timeout: 10_000 });
    expect(sessions().find((s) => s.name === name)?.devices).toEqual([]);
    await other.close();
  });

  test('a server restart shows the reconnect banner, and the terminal works again after it', async () => {
    await card(page, name).locator('.card-open').click();
    await prompt(page);
    await restartServer();
    await expect(page.locator('#banner')).toBeVisible();
    await expect(page.locator('#banner-text')).toContainText('Connection lost');
    await expect(page.locator('#banner-retry')).toBeVisible();
    await expect(page.locator('#banner')).toBeHidden({ timeout: 20_000 });
    await run(page, 'echo after-restart');
    await expect.poll(() => termText(page)).toMatch(/^after-restart\s*$/m);
    expect(sessions().find((s) => s.name === name)?.devices).toEqual(['web']);
  });

  test('Kill on a clean worktree offers plain Kill and returns to the list', async () => {
    await page.locator('#term-kill').click();
    await expect(page.locator('#kill-dialog')).toBeVisible();
    await expect(page.locator('#kill-go')).toBeVisible();
    await expect(page.locator('#kill-keep')).toBeHidden();
    await expect(page.locator('#kill-force')).toBeHidden();
    await page.locator('#kill-go').click();
    await expect(page).toHaveURL(/#\/$/);
    await expect(card(page, name)).toHaveCount(0);
    expect(sessions().some((s) => s.name === name)).toBe(false);
  });
});

test('the kill dialog for a dirty worktree lists the file, and keep leaves the directory', async ({ page }, testInfo) => {
  const slug = `dirty-${tag(testInfo)}`;
  const name = newShell(slug);
  const dir = path.join(workspace, 'demo.wt', slug);
  writeFileSync(path.join(dir, 'notes.txt'), 'unsaved\n');
  await page.goto('/?test=1');
  await card(page, name).locator('.kill').click();
  await expect(page.locator('#kill-files li')).toHaveText(['?? notes.txt']);
  await expect(page.locator('#kill-keep')).toBeVisible();
  await expect(page.locator('#kill-force')).toBeVisible();
  await expect(page.locator('#kill-go')).toBeHidden();
  await page.locator('#kill-keep').click();
  await expect(page.locator('#kill-dialog')).toBeHidden();
  await expect(card(page, name)).toHaveCount(0);
  expect(sessions().some((s) => s.name === name)).toBe(false);
  expect(existsSync(path.join(dir, 'notes.txt'))).toBe(true);
});

test('a session that does not exist says so and offers no reconnect', async ({ page }) => {
  await page.goto('/?test=1#/s/no-such-session');
  await expect(page.locator('#banner-text')).toHaveText('This session no longer exists.');
  await expect(page.locator('#banner-retry')).toBeHidden();
  await expect(page.locator('#term-state')).toHaveText('gone');
});

test.describe('without the tailscale login header', () => {
  test.use({ extraHTTPHeaders: {} });
  test('the page is the 403 page', async ({ page }) => {
    const res = await page.goto('/');
    expect(res.status()).toBe(403);
    await expect(page.locator('h1')).toHaveText('403 Forbidden');
  });
});

// The manual design pass of the plan, as files to look at: list, dialogs and terminal, both themes, two window
// sizes. Not assertions about looks; web.sh copies /work/shots out to $SHOTS.
test.describe('screenshots', () => {
  test.skip(({ browserName }) => !process.env.SHOTS || browserName !== 'chromium', 'SHOTS=1, chromium only');
  const dir = '/work/shots';
  for (const [w, h] of [[1440, 900], [1024, 768]]) {
    for (const scheme of ['light', 'dark']) {
      test(`list and terminal at ${w}x${h}, ${scheme}`, async ({ page }) => {
        mkdirSync(dir, { recursive: true });
        const shot = (what) => page.screenshot({ path: `${dir}/${what}-${w}x${h}-${scheme}.png` });
        const name = sessions().find((s) => s.name === 'demo-shot')?.name ?? newShell('shot');
        if (!sessions().some((s) => s.name === 'demo-wide')) {
          agent('new', 'demo', '--harness', 'codex', '--slug', 'wide', '--no-attach');
          writeFileSync(path.join(workspace, 'demo.wt/wide/draft.md'), 'x\n');
        }
        await page.setViewportSize({ width: w, height: h });
        await page.emulateMedia({ colorScheme: scheme });
        await page.goto('/?test=1');
        await expect(card(page, name)).toBeVisible();
        await shot('list');
        await page.locator('#new-btn').click();
        await page.locator('#new-slug').fill('fix-login');
        await shot('new');
        await page.keyboard.press('Escape');
        await card(page, 'demo-wide').locator('.kill').click();
        await expect(page.locator('#kill-files li')).toHaveCount(1);
        await shot('kill');
        await page.keyboard.press('Escape');
        await page.goto(`/?test=1#/s/${encodeURIComponent(name)}`);
        await prompt(page);
        await run(page, 'clear; ls -la /work/repo | head -20; printf "\\033[1;32mgreen \\033[1;34mblue \\033[0m\\n"');
        await page.waitForTimeout(500);
        await shot('term');
        await page.route('**/api/sessions', (r) => r.fulfill({ json: [] }));
        await page.goto('/?test=1');
        await expect(page.locator('#empty')).toBeVisible();
        await shot('empty');
      });
    }
  }
});
