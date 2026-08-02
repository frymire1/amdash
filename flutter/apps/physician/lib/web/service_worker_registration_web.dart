import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Mirrors `apps/physician/src/main.ts`'s unconditional
/// `navigator.serviceWorker.register('/firebase-messaging-sw.js')` —
/// registered on every page load (not just when a physician enables
/// alerts), since a controlling service worker with a fetch handler is
/// also what makes Chrome offer "Install AmDash".
void registerFirebaseMessagingServiceWorker() {
  web.window.navigator.serviceWorker.register('/firebase-messaging-sw.js'.toJS);
}
