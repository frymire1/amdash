// Plain JS, served as a static asset from web/ (Flutter Web copies
// everything under web/ verbatim into the build output). Copied from
// physician's identical firebase-messaging-sw.js — see that file's own
// comment for the full rationale (handles the raw Push API event
// directly rather than routing through Firebase Messaging's own
// onBackgroundMessage()/foreground-onMessage(), which was confirmed
// unreliable there; a controlling service worker with a fetch handler is
// also what makes Chrome offer "Install AmDash"). Registered
// unconditionally on every page load — see main.dart.
//
// tag differs from physician's own ('amdash-new-patient') — a distinct
// tag per app/alert-type means a connectivity alert never silently
// replaces (or gets replaced by) an unrelated notification a physician's
// own service worker might show; not actually reachable today (this is a
// separate app/origin from physician), kept distinct anyway as the
// correct convention if that ever changes.
self.addEventListener('push', (event) => {
  const payload = event.data ? event.data.json() : {};
  const title = payload.data?.title ?? 'AmDash';

  event.waitUntil(
    self.registration.showNotification(title, {
      body: payload.data?.body,
      icon: '/icons/Icon-192.png',
      tag: 'amdash-connectivity-alert',
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(self.clients.openWindow('/'));
});

// A pass-through fetch handler — no caching, "installable only, not
// offline-capable". Its only job is to exist: Chrome's installability
// check looks for a fetch handler, it doesn't require one that actually
// serves cached responses.
self.addEventListener('fetch', (event) => {
  event.respondWith(fetch(event.request));
});
