import { Component, Input } from '@angular/core';
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
export class PatientViewerComponent {
  @Input() patient?: Patient;

  mapOptions: google.maps.MapOptions = {
    center: { lat: 40.7128, lng: -74.0060 },
    zoom: 15
  };

  markerOptions: google.maps.MarkerOptions = {
    draggable: false
  };

  ngOnChanges() {
    if (this.patient?.location) {
      this.mapOptions.center = {
        lat: this.patient.location.latitude,
        lng: this.patient.location.longitude
      };
    }
  }
}
