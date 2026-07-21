import { Component, computed, input } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { GoogleMapsModule } from '@angular/google-maps';
import { Patient } from '@amdash/patients';

const DEFAULT_MARKER_POSITION: google.maps.LatLngLiteral = { lat: 40.7128, lng: -74.006 };

@Component({
  selector: 'app-patient-viewer',
  standalone: true,
  imports: [CommonModule, MatCardModule, GoogleMapsModule],
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
}
