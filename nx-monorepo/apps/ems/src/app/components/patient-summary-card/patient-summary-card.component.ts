import { Component, Input, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterLink } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { UploadedPatient } from '../../services/patient-session.service';
import { EmsTrackingService } from '../../services/ems-tracking.service';
import { PatientUploadService } from '../../services/patient-upload.service';

@Component({
  selector: 'app-patient-summary-card',
  standalone: true,
  imports: [CommonModule, RouterLink, MatButtonModule, MatIconModule],
  templateUrl: './patient-summary-card.component.html',
  styleUrls: ['./patient-summary-card.component.scss'],
})
export class PatientSummaryCardComponent {
  @Input({ required: true }) uploaded!: UploadedPatient;

  private readonly trackingService = inject(EmsTrackingService);
  private readonly patientUploadService = inject(PatientUploadService);

  readonly deleting = signal(false);
  readonly deleteError = signal<string | null>(null);

  isTracking(): boolean {
    return this.trackingService.isTracking(this.uploaded.id);
  }

  toggleTracking() {
    if (this.isTracking()) {
      this.trackingService.stopTracking(this.uploaded.id);
    } else {
      this.trackingService.startTracking(this.uploaded.id);
    }
  }

  async deletePatient() {
    const confirmed = window.confirm(`Delete ${this.uploaded.patient.name}? This cannot be undone.`);
    if (!confirmed) {
      return;
    }

    if (this.isTracking()) {
      this.trackingService.stopTracking(this.uploaded.id);
    }

    this.deleting.set(true);
    this.deleteError.set(null);

    try {
      await this.patientUploadService.deletePatient(this.uploaded.id);
    } catch (error) {
      this.deleteError.set('Failed to delete patient. Please try again.');
      console.error('Failed to delete patient', error);
    } finally {
      this.deleting.set(false);
    }
  }
}
