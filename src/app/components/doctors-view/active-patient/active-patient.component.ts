import { Component, Input } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { GoogleMapsModule } from '@angular/google-maps';
import { Patient } from '../patient-list/patient-card/patient-card.component';

@Component({
  selector: 'app-active-patient',
  standalone: true,
  imports: [CommonModule, MatCardModule, GoogleMapsModule],
  templateUrl: './active-patient.component.html',
  styleUrls: ['./active-patient.component.scss']
})
export class ActivePatientComponent {
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
