import {
  ApplicationConfig,
  inject,
  provideAppInitializer,
  provideBrowserGlobalErrorListeners,
} from '@angular/core';
import { provideRouter } from '@angular/router';
import { provideAnimationsAsync } from '@angular/platform-browser/animations/async';
import { appRoutes } from './app.routes';
import { EmsTrackingService } from './services/ems-tracking.service';

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideRouter(appRoutes),
    provideAnimationsAsync(),
    // EmsTrackingService is `providedIn: 'root'`, so it's otherwise only
    // constructed (and its reload-resume logic run — see the service's own
    // constructor comment) the first time something injects it, which today
    // is only PatientUploadComponent. Forcing that here means tracking
    // resumes on every app load regardless of which route a reload lands
    // on, not only when EMS happens to be back on a specific patient's
    // edit page.
    provideAppInitializer(() => {
      inject(EmsTrackingService);
    }),
  ],
};
