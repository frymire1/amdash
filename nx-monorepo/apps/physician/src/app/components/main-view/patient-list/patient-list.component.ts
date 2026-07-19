import { Component, computed, inject, output, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatButtonModule } from '@angular/material/button';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatIconModule } from '@angular/material/icon';
import { MatSelectModule } from '@angular/material/select';
import { HospitalService, UserProfileService } from '@amdash/auth';
import { PatientCardComponent } from './patient-card/patient-card.component';
import { Patient } from './patient-card/patient-card.component';
import { PatientService } from '../../../services/patient.service';
import { EmsLocationService } from '../../../services/ems-location.service';

export const ALL_DESTINATIONS = 'All destinations';

interface Coordinates {
  latitude: number;
  longitude: number;
}

const EARTH_RADIUS_KM = 6371;

function toRadians(degrees: number): number {
  return (degrees * Math.PI) / 180;
}

function distanceKm(from: Coordinates, to: Coordinates): number {
  const dLat = toRadians(to.latitude - from.latitude);
  const dLon = toRadians(to.longitude - from.longitude);
  const lat1 = toRadians(from.latitude);
  const lat2 = toRadians(to.latitude);

  const a = Math.sin(dLat / 2) ** 2 + Math.sin(dLon / 2) ** 2 * Math.cos(lat1) * Math.cos(lat2);
  return EARTH_RADIUS_KM * 2 * Math.asin(Math.sqrt(a));
}

@Component({
  selector: 'app-patient-list',
  standalone: true,
  imports: [
    CommonModule,
    MatButtonModule,
    MatCheckboxModule,
    MatFormFieldModule,
    MatIconModule,
    MatSelectModule,
    PatientCardComponent,
  ],
  templateUrl: './patient-list.component.html',
  styleUrls: ['./patient-list.component.scss']
})
export class PatientListComponent {
  private readonly patientService = inject(PatientService);
  private readonly emsLocationService = inject(EmsLocationService);
  private readonly userProfileService = inject(UserProfileService);
  private readonly hospitalService = inject(HospitalService);

  readonly destinationOptions = computed(() => [ALL_DESTINATIONS, ...this.hospitalService.hospitalNames()]);
  readonly selectedDestination = signal(ALL_DESTINATIONS);
  readonly filterOpen = signal(false);
  readonly sortByDistance = signal(false);

  readonly patients = this.patientService.patients;

  // physicianAppGuard + workLocationGuard together guarantee a physician/
  // nurse always has a workLocation by the time they can reach this
  // component, so this is a fixed hospital lookup rather than a live,
  // permission-gated navigator.geolocation request.
  private readonly hospitalLocation = computed<Coordinates | null>(() => {
    const hospital = this.hospitalService.findHospital(this.userProfileService.profile()?.workLocation);
    return hospital ? { latitude: hospital.latitude, longitude: hospital.longitude } : null;
  });

  readonly filteredPatients = computed(() => {
    const destination = this.selectedDestination();
    const matching =
      destination === ALL_DESTINATIONS
        ? this.patients()
        : this.patients().filter((patient) => patient.destination === destination);

    const origin = this.sortByDistance() ? this.hospitalLocation() : null;
    if (!origin) {
      return matching;
    }
    return [...matching].sort((a, b) => this.distanceTo(origin, a) - this.distanceTo(origin, b));
  });

  readonly selected = output<Patient>();

  toggleFilter() {
    this.filterOpen.update((open) => !open);
  }

  onSortByDistanceChange(enabled: boolean) {
    this.sortByDistance.set(enabled);
  }

  onPatientSelect(patient: Patient) {
    this.selected.emit(patient);
  }

  isTracked(patient: Patient): boolean {
    return this.emsLocationService.isTracked(patient.id);
  }

  private distanceTo(origin: Coordinates, patient: Patient): number {
    if (!patient.location) {
      return Number.POSITIVE_INFINITY;
    }
    return distanceKm(origin, patient.location);
  }
}
