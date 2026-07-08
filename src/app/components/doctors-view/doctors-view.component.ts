import { Component } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { PatientListComponent } from './patient-list/patient-list.component';
import { PatientViewerComponent } from './patient-viewer/patient-viewer.component';
import { Patient } from './patient-list/patient-card/patient-card.component';

@Component({
  selector: 'app-doctors-view',
  standalone: true,
  imports: [CommonModule, MatButtonModule, MatIconModule, PatientListComponent, PatientViewerComponent],
  templateUrl: './doctors-view.component.html',
  styleUrls: ['./doctors-view.component.scss']
})
export class DoctorsViewComponent {
  selectedPatient?: Patient;
  showPatientList = false;

  onPatientSelected(patient: Patient) {
    this.selectedPatient = patient;
    this.showPatientList = false;
  }

  togglePatientList() {
    this.showPatientList = !this.showPatientList;
  }
}
