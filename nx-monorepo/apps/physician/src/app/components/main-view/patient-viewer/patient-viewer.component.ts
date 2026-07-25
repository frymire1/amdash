import { Component, computed, input, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { MatIconModule } from '@angular/material/icon';
import { GoogleMapsModule } from '@angular/google-maps';
import { Patient } from '@amdash/patients';

const DEFAULT_MARKER_POSITION: google.maps.LatLngLiteral = { lat: 40.7128, lng: -74.006 };

@Component({
  selector: 'app-patient-viewer',
  standalone: true,
  imports: [CommonModule, MatButtonModule, MatCardModule, MatIconModule, GoogleMapsModule],
  templateUrl: './patient-viewer.component.html',
  styleUrls: ['./patient-viewer.component.scss']
})
export class PatientViewerComponent {
  readonly patient = input<Patient>();

  readonly mapZoom = 15;

  readonly markerOptions: google.maps.MarkerOptions = {
    draggable: false
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
}
