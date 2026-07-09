import { Component, Input, OnChanges } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { GoogleMapsModule } from '@angular/google-maps';
import { Patient } from '../patient-list/patient-card/patient-card.component';

@Component({
  selector: 'app-patient-viewer',
  standalone: true,
  imports: [CommonModule, MatCardModule, GoogleMapsModule],
  templateUrl: './patient-viewer.component.html',
  styleUrls: ['./patient-viewer.component.scss']
})
export class PatientViewerComponent implements OnChanges {
  @Input() patient?: Patient;

  mapZoom = 15;

  markerPosition: google.maps.LatLngLiteral = { lat: 40.7128, lng: -74.0060 };

  markerOptions: google.maps.MarkerOptions = {
    draggable: false
  };

  ngOnChanges() {
    if (this.patient?.location) {
      this.markerPosition = {
        lat: this.patient.location.latitude,
        lng: this.patient.location.longitude
      };
    }
  }
}
