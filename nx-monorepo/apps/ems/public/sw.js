// Plain JS, served as a static asset via this app's public-assets glob (see
// project.json). EMS has no push notifications (that's physician-only —
// see functions/src/physician.ts), so this exists purely to make the app
// installable: Chrome requires a controlling service worker with a fetch
// handler before it'll offer "Install AmDash". No caching — a pass-through,
// matching the "installable only, not offline-capable" scope this was
// built to.
self.addEventListener('fetch', (event) => {
  event.respondWith(fetch(event.request));
});
