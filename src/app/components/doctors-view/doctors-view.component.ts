import { Component } from '@angular/core';
import { CommonModule } from '@angular/common';
import { PatientListComponent } from './patient-list/patient-list.component';
import { PatientViewerComponent } from './patient-viewer/patient-viewer.component';
import { Patient } from './patient-list/patient-card/patient-card.component';

@Component({
  selector: 'app-doctors-view',
  standalone: true,
  imports: [CommonModule, PatientListComponent, PatientViewerComponent],
  templateUrl: './doctors-view.component.html',
  styleUrls: ['./doctors-view.component.scss']
})
export class DoctorsViewComponent {
  selectedPatient?: Patient;

  onPatientSelected(patient: Patient) {
    this.selectedPatient = patient;
  }

}
