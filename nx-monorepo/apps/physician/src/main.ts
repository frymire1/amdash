import { bootstrapApplication } from '@angular/platform-browser';
import { appConfig } from './app/app.config';
import { App } from './app/app';

// Registered unconditionally, before Angular even bootstraps, rather than
// only when a physician enables push alerts (see patient-alert.service.ts) —
// an active, controlling service worker with a fetch handler is what makes
// Chrome offer "Install AmDash" at all. Registering twice (this, then
// enableAlerts()'s own register() call) is harmless — the browser dedupes
// same-URL registrations.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/firebase-messaging-sw.js').catch((error) => console.error('Service worker registration failed', error));
}

bootstrapApplication(App, appConfig).catch((err) => console.error(err));
