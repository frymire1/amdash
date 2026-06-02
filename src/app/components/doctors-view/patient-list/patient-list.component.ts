import { Component, Output, EventEmitter } from '@angular/core';
import { CommonModule } from '@angular/common';
import { PatientCardComponent } from './patient-card/patient-card.component';
import { Patient } from './patient-card/patient-card.component';

@Component({
  selector: 'app-patient-list',
  standalone: true,
  imports: [CommonModule, PatientCardComponent],
  templateUrl: './patient-list.component.html',
  styleUrls: ['./patient-list.component.scss']
})
export class PatientListComponent {
  patients: Patient[] = [
    {
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
    },
    {
      name: 'Jane Smith',
      gender: 'Female',
      age: 38,
      healthcareNumber: 'HC-987654321',
      vitals: {
        heartRate: 78,
        bloodPressure: '118/76',
        oxygen: 97,
        temperature: 36.5
      },
      location: {
        latitude: 34.0522,
        longitude: -118.2437,
        address: 'Los Angeles, CA'
      }
    },
    {
      name: 'Michael Johnson',
      gender: 'Male',
      age: 52,
      healthcareNumber: 'HC-456789123',
      vitals: {
        heartRate: 82,
        bloodPressure: '130/84',
        oxygen: 96,
        temperature: 37.1
      },
      location: {
        latitude: 41.8781,
        longitude: -87.6298,
        address: 'Chicago, IL'
      }
    },
    {
      name: 'Emily Brown',
      gender: 'Female',
      age: 31,
      healthcareNumber: 'HC-321654987',
      vitals: {
        heartRate: 68,
        bloodPressure: '110/70',
        oxygen: 99,
        temperature: 36.4
      },
      location: {
        latitude: 47.6062,
        longitude: -122.3321,
        address: 'Seattle, WA'
      }
    }
  ];

  trackByHealthcareNumber(index: number, patient: Patient): string {
    return patient.healthcareNumber;
  }

  @Output() selected = new EventEmitter<Patient>();

  onPatientSelect(patient: Patient) {
    this.selected.emit(patient);
  }

}
