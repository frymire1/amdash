import { Component, input, output } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HOSPITAL_NAMES } from '@amdash/auth';

export interface PatientVitals {
  heartRate: number | string;
  bloodPressure: string;
  oxygen: number | string;
  temperature: number | string;
}

export interface PatientLocation {
  latitude: number;
  longitude: number;
  address: string;
}

export interface Patient {
  id?: string;
  name: string;
  gender: string;
  age: number | string;
  healthcareNumber: string;
  vitals: PatientVitals;
  location: PatientLocation;
  notes?: string;
  destination?: string;
}

// Same hospitals as @amdash/auth's HOSPITALS (the physician work-location
// picker), so a patient's destination and a physician's work location
// always refer to the same physical place.
export const DESTINATION_HOSPITALS: readonly string[] = HOSPITAL_NAMES;

@Component({
  selector: 'app-patient-card',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './patient-card.component.html',
  styleUrls: ['./patient-card.component.scss']
})
export class PatientCardComponent {
  readonly patient = input.required<Patient>();
  readonly isTracked = input(false);
  readonly select = output<Patient>();
}
