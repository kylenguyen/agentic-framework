// tests/e2e/web/journey.spec.mjs: one user's whole visit (docs/web-dashboard-plan.md T13, steps 1 to 10) in desktop
// Chromium and WebKit: the list, New into a shell worktree session, typing, a second tab on the same session,
// a pasted PNG, `agent attention set` from inside the pane raising the badge (and, in Chromium, a Web Push at a
// local sink, stubbed as in alerts.spec.mjs), opening the session clearing it, the sim panel with a stand-in, and
// killing the dirty worktree with keep. After every step `agent ls` in the container must agree with the page.
// Each step also checks that nothing on the page tripped the CSP, in the page's own report and in the console.
// Usage: bash tests/e2e/web.sh journey
import { test, expect } from '@playwright/test';
import { createECDH, randomBytes } from 'node:crypto';
import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { agent, home, sessions, tag, termText, workspace } from './helpers.mjs';

const STATE = process.env.AGENT_WEB_STATE ?? '/work/state';
const SUBS = path.join(STATE, 'subscriptions.json');
const SIM = path.join(home, 'bin/sim');
const SIM_STATUS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../web/fixtures/sim-status.json');
const CLIP_PNG = /\/work\/clip\/\d{8}T\d{6}Z-[A-Za-z0-9]+\.png(?= )/g;
// WebKit refuses the user-agent stylesheet of every <select> under a style-src without 'unsafe-inline' and logs
// "Refused to apply a stylesheet" at the select's line (0-based) of the page, whether the parser or a script made
// it. That is the engine's own shadow-root style, not the page's, so only that message at exactly those lines of
// index.html is let through; any other CSP message in the console fails the step.
const INDEX = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../web/public/index.html');
const SELECT_LINES = readFileSync(INDEX, 'utf8').split('\n').flatMap((l, i) => (/<select\b/.test(l) ? [i] : []));
const CSP_CONSOLE = /Refused to|Content Security Policy/;

const card = (page, name) => page.locator(`#sessions li[data-name="${name}"]`);
const shellPrompt = (page) => expect.poll(() => termText(page), { timeout: 15_000 }).toMatch(/\$ ?$/m);
async function type(page, cmd) {
  await page.locator('#term').click();
  await page.keyboard.type(cmd);
  await page.keyboard.press('Enter');
}

// Step 10: the list the page shows is exactly what `agent ls` lists, card for card.
async function listAgrees(page) {
  await expect.poll(async () => {
    const shown = await page.locator('#sessions li').evaluateAll((lis) => lis.map((li) => li.dataset.name).sort());
    return JSON.stringify(shown) === JSON.stringify(sessions().map((s) => s.name).sort());
  }, { timeout: 10_000 }).toBe(true);
}

// A page that records the CSP errors its console reports, for cspClean.
async function openPage(context, browserName) {
  const page = await context.newPage();
  page.cspConsole = [];
  page.on('console', (m) => {
    if (m.type() !== 'error' || !CSP_CONSOLE.test(m.text())) return;
    const engine = browserName === 'webkit' && /^Refused to apply a stylesheet/.test(m.text())
      && new URL(m.location().url).pathname === '/' && SELECT_LINES.includes(m.location().lineNumber);
    if (!engine) page.cspConsole.push(`${m.text()} at ${m.location().url}:${m.location().lineNumber}`);
  });
  return page;
}

async function cspClean(page) {
  expect(await page.evaluate(() => window.__csp)).toEqual([]);
  expect(page.cspConsole).toEqual([]);
}

test.use({ permissions: async ({ browserName }, use) => use(browserName === 'chromium' ? ['notifications'] : []) });

test('a visit from the list to killing a dirty worktree, agreeing with agent ls throughout', async ({ context, browserName }, testInfo) => {
  test.setTimeout(180_000);
  const slug = `j-${tag(testInfo)}`;
  const dir = path.join(workspace, 'demo.wt', slug);
  const push = browserName === 'chromium';
  const hits = [];
  const sink = http.createServer((req, res) => {
    req.resume();
    req.on('end', () => {
      hits.push(req.url);
      res.writeHead(201);
      res.end();
    });
  });
  await new Promise((r) => sink.listen(0, '127.0.0.1', r));
  rmSync(SUBS, { force: true });
  let name;

  try {
    if (push) {
      const ecdh = createECDH('prime256v1');
      ecdh.generateKeys();
      const fake = {
        endpoint: `http://127.0.0.1:${sink.address().port}/push/journey`,
        keys: { p256dh: ecdh.getPublicKey().toString('base64url'), auth: randomBytes(16).toString('base64url') },
      };
      await context.route('**/sw.js', async (r) => r.fulfill({ response: await r.fetch() }));
      await context.addInitScript((f) => {
        let current = null;
        PushManager.prototype.subscribe = async () => {
          current = {
            endpoint: f.endpoint,
            toJSON: () => ({ endpoint: f.endpoint, expirationTime: null, keys: f.keys }),
            unsubscribe: async () => { current = null; return true; },
          };
          return current;
        };
        PushManager.prototype.getSubscription = async () => current;
        Object.defineProperty(Notification, 'permission', { get: () => 'granted' });
        Notification.requestPermission = async () => 'granted';
      }, fake);
    }
    const a = await openPage(context, browserName);

    await test.step('1. the list loads', async () => {
      await a.goto('/?test=1');
      await expect(card(a, 'demo')).toBeVisible();
      await listAgrees(a);
      if (push) {
        await a.locator('#alerts-enable').click();
        await expect(a.locator('#alerts-enable')).toHaveText('Alerts on');
        await expect.poll(() => existsSync(SUBS)).toBe(true);
      }
      await cspClean(a);
    });

    await test.step('2. New makes demo with slug j and harness shell', async () => {
      await a.locator('#new-btn').click();
      await a.locator('#new-repo').selectOption('demo');
      await a.locator('#new-harness').selectOption('shell');
      await a.locator('#new-slug').fill(slug);
      await a.locator('#new-create').click();
      await expect(a).toHaveURL(new RegExp(`#/s/demo-${slug}$`));
      name = decodeURIComponent(new URL(a.url()).hash.slice(4));
      await expect(a.locator('#term-name')).toHaveText(name);
      await expect(a.locator('#term-state')).toHaveText('running');
      await shellPrompt(a);
      const s = sessions().find((x) => x.name === name);
      expect(s).toMatchObject({ harness: 'shell', repo: 'demo', branch: `agent/${slug}`, worktree: true, state: 'running', devices: ['web'] });
      expect(existsSync(dir)).toBe(true);
    });

    await test.step('3. a typed command runs', async () => {
      await type(a, 'echo journey-one');
      await expect.poll(() => termText(a)).toMatch(/^journey-one\s*$/m);
      await cspClean(a);
    });

    const b = await openPage(context, browserName);
    await test.step('4. a second tab on the same session shares its output', async () => {
      await b.goto(`/?test=1#/s/${encodeURIComponent(name)}`);
      await expect(b.locator('#term-state')).toHaveText('running');
      await expect.poll(() => termText(b), { timeout: 15_000 }).toMatch(/^journey-one\s*$/m);
      await type(b, 'echo journey-two');
      await expect.poll(() => termText(a)).toMatch(/^journey-two\s*$/m);
      await expect.poll(() => termText(b)).toMatch(/^journey-two\s*$/m);
      // One view per tab, each the web device.
      expect(sessions().find((x) => x.name === name).devices).toEqual(['web', 'web']);
      await cspClean(b);
    });

    await test.step('5. a pasted PNG types its path', async () => {
      await a.evaluate(async () => {
        const c = document.createElement('canvas');
        c.width = 4;
        c.height = 3;
        c.getContext('2d').fillRect(0, 0, 4, 3);
        const blob = await new Promise((r) => c.toBlob(r, 'image/png'));
        const dt = new DataTransfer();
        dt.items.add(new File([blob], 'image.png', { type: 'image/png' }));
        const ev = new Event('paste', { bubbles: true, cancelable: true });
        Object.defineProperty(ev, 'clipboardData', { value: dt });
        document.querySelector('#term .xterm-helper-textarea').dispatchEvent(ev);
      });
      let p = null;
      await expect.poll(async () => (p = (await termText(a)).match(CLIP_PNG)?.at(-1) ?? null), { timeout: 15_000 }).not.toBeNull();
      expect(existsSync(p)).toBe(true);
      // The other tab sees the typed path too; then drop the line.
      await expect.poll(() => termText(b)).toContain(p);
      await a.locator('#term').click();
      await a.keyboard.press('Control+C');
    });

    await test.step('6. agent attention set in the pane shows the badge and pushes', async () => {
      await a.locator('#back').click();
      await expect(card(a, name)).toBeVisible();
      const before = hits.length;
      await type(b, 'agent attention set --reason permission');
      await expect(card(a, name).locator('.badge.attention')).toHaveAttribute('data-attention', 'permission', { timeout: 8000 });
      expect(sessions().find((x) => x.name === name).attention).toMatchObject({ reason: 'permission', source: 'agent' });
      if (push) await expect.poll(() => hits.slice(before), { timeout: 8000 }).toContain('/push/journey');
      await b.close();
      await expect.poll(() => sessions().find((x) => x.name === name).devices).toEqual([]);
      await listAgrees(a);
    });

    await test.step('7. opening the session clears the badge', async () => {
      await card(a, name).locator('.card-open').click();
      await expect(a.locator('#term-state')).toHaveText('running');
      await expect.poll(() => sessions().find((x) => x.name === name).attention).toBeNull();
      await a.locator('#back').click();
      await expect(card(a, name).locator('.badge.attention')).toHaveAttribute('data-attention', '');
      await listAgrees(a);
    });

    await test.step('8. the sim panel shows the stand-in', async () => {
      writeFileSync(SIM, `#!/bin/sh\ncat '${SIM_STATUS}'\n`, { mode: 0o755 });
      await a.reload();
      await expect(a.locator('#sim-panel')).toBeVisible();
      await expect(a.locator('.sim-slot')).toHaveCount(5);
      await listAgrees(a);
      await cspClean(a);
    });

    await test.step('9. a dirty worktree killed with keep leaves its directory', async () => {
      writeFileSync(path.join(dir, 'journey.txt'), 'unsaved\n');
      await card(a, name).locator('.kill').click();
      await expect(a.locator('#kill-files li')).toHaveText(['?? journey.txt']);
      await a.locator('#kill-keep').click();
      await expect(a.locator('#kill-dialog')).toBeHidden();
      await expect(card(a, name)).toHaveCount(0);
      expect(sessions().some((x) => x.name === name)).toBe(false);
      expect(existsSync(path.join(dir, 'journey.txt'))).toBe(true);
      await listAgrees(a);
      await cspClean(a);
    });
  } finally {
    sink.close();
    rmSync(SIM, { force: true });
    rmSync(SUBS, { force: true });
    if (name && sessions().some((x) => x.name === name)) agent('kill', name, '--force');
  }
});
