// tests/e2e/web/alerts.spec.mjs: needs-input alerts (docs/web-dashboard-plan.md T10) in desktop Chromium with the
// notification permission granted: the badge and title count from `agent attention set`, opening the session
// clearing it, and Web Push. A headless browser has no push service to subscribe with, so the page's PushManager
// is stubbed to hand back a subscription whose endpoint is a plain-HTTP sink in this process (inside the container,
// on loopback, where the server accepts it) with a real P-256 key and auth secret; the server then encrypts and
// sends to it exactly as it would to a real push service. Playwright's headless Chromium also reports the
// notification permission as denied whatever the context grants, so Notification's permission is stubbed with it.
import { test, expect } from '@playwright/test';
import { createECDH, randomBytes } from 'node:crypto';
import { existsSync, readFileSync, rmSync, statSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { agent, newShell, sessions, tag } from './helpers.mjs';

const STATE = process.env.AGENT_WEB_STATE ?? '/work/state';
const SUBS = path.join(STATE, 'subscriptions.json');
const card = (page, name) => page.locator(`#sessions li[data-name="${name}"]`);
const subs = () => (existsSync(SUBS) ? JSON.parse(readFileSync(SUBS, 'utf8')) : []);

test.use({ permissions: ['notifications'] });

test.describe('needs-input alerts', () => {
  test.describe.configure({ mode: 'serial' });
  let name;
  let sink;
  const hits = [];

  test.beforeAll(async ({}, testInfo) => {
    name = newShell(`al-${tag(testInfo)}`);
    sink = http.createServer((req, res) => {
      req.resume();
      req.on('end', () => {
        hits.push({ url: req.url, headers: req.headers });
        res.writeHead(201);
        res.end();
      });
    });
    await new Promise((r) => sink.listen(0, '127.0.0.1', r));
    rmSync(SUBS, { force: true });
  });
  test.afterAll(() => {
    sink?.close();
    if (sessions().some((s) => s.name === name)) agent('kill', name, '--force');
    rmSync(SUBS, { force: true });
  });

  test('a hook attention shows a badge and the title count, and opening the session clears it', async ({ page }) => {
    await page.goto('/?test=1');
    await expect(card(page, name)).toBeVisible();
    // Other specs may have left a session needing attention (an exited one, say): count from what the page sees.
    const others = (await (await page.request.get('/api/sessions')).json())
      .filter((s) => s.name !== name && s.attention).length;
    agent('attention', 'set', '--reason', 'permission', '--source', 'claude', name);
    await expect(card(page, name).locator('.badge.attention')).toHaveAttribute('data-attention', 'permission', { timeout: 4000 });
    await expect(page).toHaveTitle(`(${others + 1}) Agents`);
    // Cards that need the user come first.
    const order = await page.locator('#sessions li').evaluateAll((lis) => lis.map((li) => li.classList.contains('needs-you')));
    expect(order.slice(0, others + 1).every(Boolean) && !order.slice(others + 1).some(Boolean)).toBe(true);

    await card(page, name).locator('.card-open').click();
    await expect(page.locator('#term-state')).toHaveText('running');
    await expect.poll(() => sessions().find((s) => s.name === name).attention).toBeNull();
    await page.goto('/?test=1');
    await expect(card(page, name).locator('.badge.attention')).toHaveAttribute('data-attention', '');
    await expect(page).toHaveTitle(others ? `(${others}) Agents` : 'Agents');
    expect(await page.evaluate(() => window.__csp)).toEqual([]);
  });

  test('Enable alerts stores one subscription, and a test push and a rising edge reach the sink', async ({ page, context }) => {
    // Chromium fetches the worker script without Playwright's extraHTTPHeaders; add the login as tailscale serve would.
    await context.route('**/sw.js', async (r) => r.fulfill({ response: await r.fetch() }));
    const ecdh = createECDH('prime256v1');
    ecdh.generateKeys();
    const fake = {
      endpoint: `http://127.0.0.1:${sink.address().port}/push/${tag(test.info())}`,
      keys: { p256dh: ecdh.getPublicKey().toString('base64url'), auth: randomBytes(16).toString('base64url') },
    };
    await page.addInitScript((f) => {
      let current = null;
      const make = () => ({
        endpoint: f.endpoint,
        toJSON: () => ({ endpoint: f.endpoint, expirationTime: null, keys: f.keys }),
        unsubscribe: async () => { current = null; return true; },
      });
      PushManager.prototype.subscribe = async function (opts) {
        window.__pushKey = opts?.applicationServerKey?.byteLength ?? 0;
        current = make();
        return current;
      };
      PushManager.prototype.getSubscription = async () => current;
      Object.defineProperty(Notification, 'permission', { get: () => 'granted' });
      Notification.requestPermission = async () => 'granted';
    }, fake);

    await page.goto('/?test=1');
    const enable = page.locator('#alerts-enable');
    await expect(enable).toHaveText('Enable alerts');
    await expect(page.locator('#alerts-test')).toBeHidden();
    await enable.click();
    await expect(enable).toHaveAttribute('aria-pressed', 'true');
    await expect(enable).toHaveText('Alerts on');
    expect(await page.evaluate(() => window.__pushKey)).toBe(65);   // the VAPID public key, decoded
    await expect.poll(subs).toEqual([{ endpoint: fake.endpoint, keys: fake.keys }]);
    expect(statSync(SUBS).mode & 0o777).toBe(0o600);

    await page.locator('#alerts-test').click();
    await expect(page.locator('#paste-toast')).toHaveText('Test alert sent');
    await expect.poll(() => hits.length).toBe(1);
    expect(hits[0].headers['content-encoding']).toBe('aes128gcm');
    expect(hits[0].headers.ttl).toBe('3600');
    expect(hits[0].headers.authorization).toMatch(/^vapid t=/);

    agent('attention', 'set', '--reason', 'done', '--source', 'claude', name);
    await expect.poll(() => hits.length, { timeout: 8000 }).toBe(2);
    agent('attention', 'clear', name);
  });
});
