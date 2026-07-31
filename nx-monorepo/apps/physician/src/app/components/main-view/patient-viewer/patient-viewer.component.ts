import { Component, DestroyRef, computed, effect, inject, input, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { MatIconModule } from '@angular/material/icon';
import { GoogleMapsModule } from '@angular/google-maps';
import { Patient } from '@amdash/patients';
import { ActiveLocation } from '../../../classes/active-location';
import { EmsLocationService } from '../../../services/ems-location.service';

const DEFAULT_MARKER_POSITION: google.maps.LatLngLiteral = { lat: 40.7128, lng: -74.006 };

@Component({
  selector: 'app-patient-viewer',
  standalone: true,
  imports: [CommonModule, MatButtonModule, MatCardModule, MatIconModule, GoogleMapsModule],
  templateUrl: './patient-viewer.component.html',
  styleUrls: ['./patient-viewer.component.scss']
})
export class PatientViewerComponent {
  private readonly emsLocationService = inject(EmsLocationService);
  private readonly destroyRef = inject(DestroyRef);

  readonly patient = input<Patient>();

  readonly mapZoom = 15;

  readonly markerOptions: google.maps.MarkerOptions = {
    draggable: false
  };

  // The vehicle marker, styled distinctly from the default pickup pin, in
  // the same blue already used for accents elsewhere on this card (see
  // patient-viewer.component.scss's .vital-item border/value color). A
  // getter rather than a field initializer: the latter runs unconditionally
  // at construction time, but `google.maps.SymbolPath` is a real runtime
  // value from the Maps JS API script loaded in index.html — unavailable in
  // the unit-test (jsdom) environment, which never loads it. A getter only
  // evaluates when the template actually reads it, i.e. only once a vehicle
  // position exists to render.
  get vehicleMarkerOptions(): google.maps.MarkerOptions {
    return {
      icon: {
        path: google.maps.SymbolPath.CIRCLE,
        scale: 8,
        fillColor: '#0284c7',
        fillOpacity: 1,
        strokeColor: '#ffffff',
        strokeWeight: 2,
      },
    };
  }

  // EMS only publishes a fresh fix every 15s (see ems-tracking.service.ts),
  // which would otherwise make the marker visibly jump on every update.
  // This holds the animation's current on-screen position, eased between
  // the last two known fixes by the requestAnimationFrame loop below,
  // rather than snapping straight to each new fix.
  readonly activeLocation = computed(() => this.emsLocationService.activeLocation(this.patient()?.id));
  readonly animatedVehiclePosition = signal<google.maps.LatLngLiteral | undefined>(undefined);

  private animationFrameId: number | undefined;

  constructor() {
    effect(() => {
      const location = this.activeLocation();
      this.stopAnimation();

      if (!location || typeof location.latitude !== 'number' || typeof location.longitude !== 'number') {
        this.animatedVehiclePosition.set(undefined);
        return;
      }

      this.animateTo(location);
    });

    this.destroyRef.onDestroy(() => this.stopAnimation());
  }

  // Google Maps renders its own native fullscreen control in the map's
  // top-right corner by default — the same corner map-container__expand-btn
  // (our own CSS-overlay toggle, added for iOS Safari, which doesn't
  // implement the Fullscreen API Google's control relies on) occupies. On
  // platforms where the Fullscreen API IS available (Windows, Android, macOS
  // desktop browsers), Google still renders its own control there too,
  // stacking both buttons on top of each other. Disabling Google's native
  // one leaves a single, consistent control on every platform.
  readonly mapOptions: google.maps.MapOptions = {
    fullscreenControl: false,
  };

  readonly markerPosition = computed<google.maps.LatLngLiteral>(() => {
    const location = this.patient()?.location;
    return location ? { lat: location.latitude, lng: location.longitude } : DEFAULT_MARKER_POSITION;
  });

  // A CSS overlay rather than the real Fullscreen API (element.requestFullscreen)
  // — iOS Safari doesn't implement the Fullscreen API at all (Apple
  // restricts it), which is also why Google Maps' own built-in fullscreen
  // control doesn't render there. This works identically on every platform
  // since it's just layout, not a browser capability iOS blocks.
  readonly isMapExpanded = signal(false);

  toggleMapExpanded() {
    this.isMapExpanded.update((expanded) => !expanded);
    // Prevents the page behind the overlay from scrolling while expanded —
    // the overlay covers the viewport either way, but this keeps scroll
    // position from drifting underneath it.
    document.body.style.overflow = this.isMapExpanded() ? 'hidden' : '';
  }

  // A field EMS left blank on upload isn't `undefined` for every field —
  // required-typed ones (name, vitals, etc.) instead get the app's own
  // 'Unknown' sentinel string (see PatientUploadComponent.onSubmit) since
  // the Patient type doesn't make them optional. Treat both the same way so
  // this reads "not added" rather than a confusing literal "Unknown".
  protected isProvided(value: string | number | undefined): boolean {
    return typeof value === 'number' || (typeof value === 'string' && value !== '' && value !== 'Unknown');
  }

  // Eases the marker from the previous fix to the current one over the
  // real gap between their timestamps, rather than jumping. Without a
  // usable previous fix (the very first update for this patient, or a gap
  // long enough that the two points can't be meaningfully interpolated),
  // it just shows the current fix immediately.
  private animateTo(location: ActiveLocation) {
    const { latitude, longitude, previousLatitude, previousLongitude, previousUpdatedAtMs, updatedAtMs } = location;

    const hasPreviousFix =
      typeof previousLatitude === 'number' &&
      typeof previousLongitude === 'number' &&
      typeof previousUpdatedAtMs === 'number' &&
      previousUpdatedAtMs < updatedAtMs;

    if (!hasPreviousFix) {
      this.animatedVehiclePosition.set({ lat: latitude as number, lng: longitude as number });
      return;
    }

    const durationMs = updatedAtMs - previousUpdatedAtMs;

    const step = () => {
      const t = Math.min(Math.max((Date.now() - previousUpdatedAtMs) / durationMs, 0), 1);

      this.animatedVehiclePosition.set({
        lat: previousLatitude + ((latitude as number) - previousLatitude) * t,
        lng: previousLongitude + ((longitude as number) - previousLongitude) * t,
      });

      if (t < 1) {
        this.animationFrameId = requestAnimationFrame(step);
      }
    };

    step();
  }

  private stopAnimation() {
    if (this.animationFrameId !== undefined) {
      cancelAnimationFrame(this.animationFrameId);
      this.animationFrameId = undefined;
    }
  }
}
