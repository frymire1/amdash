// Plain JS, not part of the Angular/TS build — served as a static asset via
// this app's existing public-assets glob (see project.json), the same way
// favicon.ico already is. Registered unconditionally on every page load
// (see main.ts), not just when a physician enables alerts — this is also
// what makes the app installable as a PWA: Chrome requires a controlling
// service worker with a fetch handler before it'll offer "Install AmDash".
//
// Handles the raw Push API event directly rather than going through
// Firebase Messaging's own onBackgroundMessage()/foreground-onMessage()
// routing (which requires importing the Firebase SDK here too) — verified
// against the live site that Firebase's own routing silently drops the
// message in cases its window-focus heuristic gets wrong, while a direct
// `push` listener fires reliably every time regardless of whether the app
// tab is open, closed, focused, or backgrounded. This always shows an OS
// notification, so there's no separate "quiet foreground toast" case to
// keep in sync — one path, proven to work.
self.addEventListener('push', (event) => {
  const payload = event.data ? event.data.json() : {};
  const title = payload.data?.title ?? 'AmDash';

  event.waitUntil(
    self.registration.showNotification(title, {
      body: payload.data?.body,
      icon: '/icon-192.png',
      tag: 'amdash-new-patient',
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(self.clients.openWindow('/'));
});

// A pass-through fetch handler — no caching, matching the "installable
// only, not offline-capable" scope this was built to (see the plan this
// was scoped against). Its only job is to exist: Chrome's installability
// check looks for a fetch handler, it doesn't require one that actually
// serves cached responses.
self.addEventListener('fetch', (event) => {
  event.respondWith(fetch(event.request));
});
