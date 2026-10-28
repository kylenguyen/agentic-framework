// tests/e2e/web/paste.spec.mjs: image and file paste in the terminal view (docs/web-dashboard-plan.md T8) in
// Chromium and WebKit. A synthetic paste of a PNG, a dropped text file, a dropped JPEG (converted to PNG in the
// page) and the paperclip each type a path plus a space into a shell session, and the file is there in the
// container's spools (CLIP_BRIDGE_SPOOL=/work/clip/latest, AGENT_WEB_FILES=/work/files). A plain-text paste still
// reaches xterm as text. Events are dispatched with clipboardData/dataTransfer defined on a plain Event, since
// WebKit will not take them in the ClipboardEvent/DragEvent constructors.
// Usage: bash tests/e2e/web.sh paste
import { test, expect } from '@playwright/test';
import { agent, newShell, sh, termText } from './helpers.mjs';

const CLIP_PNG = /\/work\/clip\/\d{8}T\d{6}Z-[A-Za-z0-9]+\.png(?= )/g;
const FILES = (name) => new RegExp(`/work/files/\\d{8}T\\d{6}Z-[0-9a-f]{8}-${name.replace('.', '\\.')}(?= )`, 'g');

// Builds the files in the page: an image drawn on a canvas (so it is a real PNG or JPEG), or text.
async function dispatch(page, kind, files) {
  await page.evaluate(async ({ kind, files }) => {
    const make = async (f) => {
      if (f.text !== undefined) return new File([f.text], f.name, { type: f.type });
      const c = document.createElement('canvas');
      c.width = 4;
      c.height = 3;
      const g = c.getContext('2d');
      g.fillStyle = '#c33';
      g.fillRect(0, 0, 4, 3);
      const blob = await new Promise((r) => c.toBlob(r, f.type));
      return new File([blob], f.name, { type: f.type });
    };
    const dt = new DataTransfer();
    for (const f of files) {
      if (f.plain !== undefined) dt.setData('text/plain', f.plain);
      else dt.items.add(await make(f));
    }
    const ev = new Event(kind, { bubbles: true, cancelable: true });
    if (kind === 'paste') {
      Object.defineProperty(ev, 'clipboardData', { value: dt });
      document.querySelector('#term .xterm-helper-textarea').dispatchEvent(ev);
    } else {
      Object.defineProperty(ev, 'dataTransfer', { value: dt });
      document.querySelector('#term').dispatchEvent(ev);
    }
  }, { kind, files });
}

// The path most recently typed into the buffer that matches re.
async function typedPath(page, re) {
  let last = null;
  await expect.poll(async () => {
    const all = (await termText(page)).match(re) ?? [];
    last = all.at(-1) ?? null;
    return last;
  }, { timeout: 15_000 }).not.toBeNull();
  return last;
}

const exists = (p) => sh(`test -f '${p}' && echo yes || echo no`) === 'yes';

test.describe('paste and upload', () => {
  test.describe.configure({ mode: 'serial' });
  let page;
  let name;

  test.beforeAll(async ({ browser }) => {
    name = newShell();
    page = await browser.newPage();
    await page.goto(`/?test=1#/s/${encodeURIComponent(name)}`);
    await expect.poll(() => termText(page), { timeout: 15_000 }).toMatch(/\$ ?$/m);
  });
  test.afterEach(async () => {
    // Abandon the typed line so the next case starts at a fresh prompt.
    await page.locator('#term').click();
    await page.keyboard.press('Control+C');
  });
  test.afterAll(async () => {
    expect(await page.evaluate(() => window.__csp)).toEqual([]);
    await page?.close();
    agent('kill', name);
  });

  test('a pasted PNG types its clip spool path and a space', async () => {
    const before = (await termText(page)).match(CLIP_PNG)?.length ?? 0;
    await dispatch(page, 'paste', [{ name: 'image.png', type: 'image/png' }]);
    await expect.poll(async () => (await termText(page)).match(CLIP_PNG)?.length ?? 0).toBe(before + 1);
    const p = await typedPath(page, CLIP_PNG);
    expect(exists(p)).toBe(true);
    expect(sh(`head -c 8 '${p}' | od -An -tx1 | tr -d ' \\n'`)).toBe('89504e470d0a1a0a');
    await expect(page.locator('#paste-toast')).toHaveAttribute('data-kind', 'ok');
  });

  test('a plain-text paste still reaches the terminal as text', async () => {
    await dispatch(page, 'paste', [{ plain: 'echo pasted-text-t8' }]);
    await expect.poll(() => termText(page)).toMatch(/\$ echo pasted-text-t8/);
    await page.keyboard.press('Enter');
    await expect.poll(() => termText(page)).toMatch(/^pasted-text-t8\s*$/m);
  });

  test('a dropped text file lands in the files spool', async () => {
    await dispatch(page, 'drop', [{ name: 'my notes.txt', type: 'text/plain', text: 'hello from t8\n' }]);
    const p = await typedPath(page, FILES('my_notes.txt'));
    expect(sh(`cat '${p}'`)).toBe('hello from t8');
    expect(sh(`stat -c %a '${p}'`)).toBe('600');
  });

  test('a dropped JPEG arrives as a PNG', async () => {
    const before = (await termText(page)).match(CLIP_PNG)?.length ?? 0;
    await dispatch(page, 'drop', [{ name: 'photo.jpg', type: 'image/jpeg' }]);
    await expect.poll(async () => (await termText(page)).match(CLIP_PNG)?.length ?? 0).toBe(before + 1);
    const p = await typedPath(page, CLIP_PNG);
    expect(exists(p)).toBe(true);
    expect(sh(`head -c 8 '${p}' | od -An -tx1 | tr -d ' \\n'`)).toBe('89504e470d0a1a0a');
  });

  test('the paperclip uploads what is picked', async () => {
    await expect(page.locator('#paste-attach')).toBeVisible();
    await page.locator('#paste-picker').setInputFiles({
      name: 'report.csv', mimeType: 'text/csv', buffer: Buffer.from('a,b\n1,2\n'),
    });
    const p = await typedPath(page, FILES('report.csv'));
    expect(sh(`cat '${p}'`)).toBe('a,b\n1,2');
  });
});
