import { Component, Input, Output, EventEmitter } from '@angular/core';
import { CommonModule } from '@angular/common';

export interface PatientVitals {
  heartRate: number;
  bloodPressure: string;
  oxygen: number;
  temperature: number;
}

export interface PatientLocation {
  latitude: number;
  longitude: number;
  address: string;
}

export interface Patient {
  name: string;
  gender: string;
  age: number;
  healthcareNumber: string;
  vitals: PatientVitals;
  location: PatientLocation;
}

@Component({
  selector: 'app-patient-card',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './patient-card.component.html',
  styleUrls: ['./patient-card.component.scss']
})
export class PatientCardComponent {
  @Input() patient: Patient = {
    name: 'John Doe',
    gender: 'Male',
    age: 45,
    healthcareNumber: 'HC-123456789',
    vitals: {
      heartRate: 72,
      bloodPressure: '120/80',
      oxygen: 98,
      temperature: 36.7
    },
    location: {
      latitude: 40.7128,
      longitude: -74.0060,
      address: 'New York, NY'
    }
  };
  @Output() select = new EventEmitter<Patient>();
}
