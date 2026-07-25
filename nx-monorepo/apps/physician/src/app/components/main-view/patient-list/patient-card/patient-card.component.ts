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
  readonly patientSelected = output<Patient>();

  // A field EMS left blank on upload isn't `undefined` for every field —
  // required-typed ones (name, vitals, etc.) instead get the app's own
  // 'Unknown' sentinel string (see PatientUploadComponent.onSubmit) since
  // the Patient type doesn't make them optional. Treat both the same way so
  // the card reads "not added" rather than a confusing literal "Unknown".
  protected isProvided(value: string | number | undefined): boolean {
    return typeof value === 'number' || (typeof value === 'string' && value !== '' && value !== 'Unknown');
  }
}
