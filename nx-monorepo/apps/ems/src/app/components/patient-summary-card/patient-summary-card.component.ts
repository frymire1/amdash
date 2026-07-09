import { Component, Input } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterLink } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { UploadedPatient } from '../../services/patient-session.service';

@Component({
  selector: 'app-patient-summary-card',
  standalone: true,
  imports: [CommonModule, RouterLink, MatButtonModule, MatIconModule],
  templateUrl: './patient-summary-card.component.html',
  styleUrls: ['./patient-summary-card.component.scss'],
})
export class PatientSummaryCardComponent {
  @Input({ required: true }) uploaded!: UploadedPatient;
}
