import { Component, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterLink } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { PatientSessionService } from '../../services/patient-session.service';
import { PatientSummaryCardComponent } from '../patient-summary-card/patient-summary-card.component';

@Component({
  selector: 'app-home',
  standalone: true,
  imports: [CommonModule, RouterLink, MatButtonModule, MatIconModule, PatientSummaryCardComponent],
  templateUrl: './home.component.html',
  styleUrls: ['./home.component.scss'],
})
export class HomeComponent {
  private readonly patientSessionService = inject(PatientSessionService);

  readonly uploadedPatients = this.patientSessionService.uploadedPatients;
}
