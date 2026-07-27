import { Component, DestroyRef, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';

// App-wide, not tied to any specific form submit — the browser's own
// online/offline events fire regardless of what the user happens to be
// doing, so this is the one place that can reliably tell them their
// connection dropped rather than leaving them to guess why, say, a spinner
// never seems to finish (see with-timeout.ts for the per-write side of that
// same problem). Rendered once per app, outside <router-outlet> alongside
// the nav bar, so it stays visible across every route.
@Component({
  selector: 'lib-offline-banner',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './offline-banner.component.html',
  styleUrls: ['./offline-banner.component.scss'],
})
export class OfflineBannerComponent {
  private readonly destroyRef = inject(DestroyRef);

  readonly isOffline = signal(!navigator.onLine);

  constructor() {
    const setOffline = () => this.isOffline.set(true);
    const setOnline = () => this.isOffline.set(false);

    window.addEventListener('offline', setOffline);
    window.addEventListener('online', setOnline);

    this.destroyRef.onDestroy(() => {
      window.removeEventListener('offline', setOffline);
      window.removeEventListener('online', setOnline);
    });
  }
}
