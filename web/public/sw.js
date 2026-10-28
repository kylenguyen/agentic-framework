// web/public/sw.js: the service worker (docs/web-dashboard-plan.md T7), registered by app.mjs. It exists so the
// page installs as an app and, later, receives Web Push. It caches nothing and has no fetch handler: every
// request, /api/ and the page alike, goes to the network, so the app is never older than the server it talks to.

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

// --- alerts ---
// T10: a push from web/lib/push.mjs carries {title, body, url, tag}, where url is /#/s/<name>. It is shown unless a
// focused window is already on that session; a click focuses a dashboard window and sends it there (the page
// listens for the message in app.mjs's alerts section), or opens a new one.
self.addEventListener('push', (e) => {
  let d = {};
  try {
    d = e.data?.json() ?? {};
  } catch { /* not JSON: a bare notification still says something needs looking at */ }
  const url = new URL(typeof d.url === 'string' ? d.url : '/', self.location.origin).href;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (wins.some((c) => c.focused && c.url === url)) return;
    await self.registration.showNotification(d.title || 'Agents', {
      body: d.body || '',
      tag: d.tag || 'agent-web',
      renotify: true,
      icon: '/icons/icon-192.png',
      data: { url },
    });
  })());
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = e.notification.data?.url || new URL('/', self.location.origin).href;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const win = wins.find((c) => new URL(c.url).origin === self.location.origin);
    if (!win) {
      await self.clients.openWindow(url);
      return;
    }
    win.postMessage({ type: 'open', url });
    await win.focus();
  })());
});
