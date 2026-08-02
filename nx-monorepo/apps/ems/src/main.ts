import { bootstrapApplication } from '@angular/platform-browser';
import { appConfig } from './app/app.config';
import { App } from './app/app';

// Registered unconditionally, before Angular even bootstraps — an active,
// controlling service worker with a fetch handler is what makes Chrome
// offer "Install AmDash" at all (see public/sw.js).
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch((error) => console.error('Service worker registration failed', error));
}

bootstrapApplication(App, appConfig).catch((err) => console.error(err));
