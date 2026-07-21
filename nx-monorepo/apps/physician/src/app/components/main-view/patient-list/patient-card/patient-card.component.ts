import { Component, input, output } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Patient } from '@amdash/patients';

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
