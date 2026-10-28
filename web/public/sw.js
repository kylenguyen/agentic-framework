// web/public/sw.js: the service worker (docs/web-dashboard-plan.md T7), registered by app.mjs. It exists so the
// page installs as an app and, later, receives Web Push. It caches nothing and has no fetch handler: every
// request, /api/ and the page alike, goes to the network, so the app is never older than the server it talks to.

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

// --- alerts ---
// T10 adds the push and notificationclick handlers here.
