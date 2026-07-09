import { Component, inject, output } from '@angular/core';
import { CommonModule } from '@angular/common';
import { PatientCardComponent } from './patient-card/patient-card.component';
import { Patient } from './patient-card/patient-card.component';
import { PatientService } from '../../../services/patient.service';
import { EmsLocationService } from '../../../services/ems-location.service';

@Component({
  selector: 'app-patient-list',
  standalone: true,
  imports: [CommonModule, PatientCardComponent],
  templateUrl: './patient-list.component.html',
  styleUrls: ['./patient-list.component.scss']
})
export class PatientListComponent {
  private readonly patientService = inject(PatientService);
  private readonly emsLocationService = inject(EmsLocationService);

  readonly patients = this.patientService.patients;

  readonly selected = output<Patient>();

  onPatientSelect(patient: Patient) {
    this.selected.emit(patient);
  }

  isTracked(patient: Patient): boolean {
    return this.emsLocationService.isTracked(patient.id);
  }
}
