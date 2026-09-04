import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Mirrors physician's identical service_worker_registration_web.dart —
/// registered on every page load (not just once EMS's alert registration
/// actually runs), since a controlling service worker with a fetch
/// handler is also what makes Chrome offer "Install AmDash".
void registerFirebaseMessagingServiceWorker() {
  web.window.navigator.serviceWorker.register('/firebase-messaging-sw.js'.toJS);
}
