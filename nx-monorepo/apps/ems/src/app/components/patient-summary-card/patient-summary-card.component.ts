import { Component, Input, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterLink } from '@angular/router';
import { firstValueFrom } from 'rxjs';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatDialog } from '@angular/material/dialog';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { UploadedPatient } from '../../classes/uploaded-patient';
import { EmsTrackingService } from '../../services/ems-tracking.service';
import { PatientUploadService } from '../../services/patient-upload.service';
import { ConfirmDialogComponent } from '../confirm-dialog/confirm-dialog.component';

@Component({
  selector: 'app-patient-summary-card',
  standalone: true,
  imports: [CommonModule, RouterLink, MatButtonModule, MatIconModule, MatProgressSpinnerModule],
  templateUrl: './patient-summary-card.component.html',
  styleUrls: ['./patient-summary-card.component.scss'],
})
export class PatientSummaryCardComponent {
  @Input({ required: true }) uploaded!: UploadedPatient;

  private readonly trackingService = inject(EmsTrackingService);
  private readonly patientUploadService = inject(PatientUploadService);
  private readonly dialog = inject(MatDialog);

  readonly deleting = signal(false);
  readonly deleteError = signal<string | null>(null);
  readonly completing = signal(false);
  readonly completeError = signal<string | null>(null);

  isTracking(): boolean {
    return this.trackingService.isTracking(this.uploaded.id);
  }

  async deletePatient() {
    const dialogRef = this.dialog.open(ConfirmDialogComponent, {
      data: {
        title: 'Delete patient?',
        message: `Delete ${this.uploaded.patient.name}? This cannot be undone.`,
        confirmLabel: 'Delete',
      },
    });

    const confirmed = await firstValueFrom(dialogRef.afterClosed());
    if (!confirmed) {
      return;
    }

    this.trackingService.stopTracking(this.uploaded.id);

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

  // Stops live tracking (same as deletePatient() does) and marks the
  // patient complete — see completeTransport() in patient-upload.service.ts
  // for what happens to the record afterward.
  async completeTransport() {
    const dialogRef = this.dialog.open(ConfirmDialogComponent, {
      data: {
        title: 'Complete transport?',
        message: `Mark ${this.uploaded.patient.name}'s transport as complete? Live tracking will stop and it will no longer appear as active.`,
        confirmLabel: 'Complete Transport',
      },
    });

    const confirmed = await firstValueFrom(dialogRef.afterClosed());
    if (!confirmed) {
      return;
    }

    this.trackingService.stopTracking(this.uploaded.id);

    this.completing.set(true);
    this.completeError.set(null);

    try {
      await this.patientUploadService.completeTransport(this.uploaded.id);
    } catch (error) {
      this.completeError.set('Failed to complete transport. Please try again.');
      console.error('Failed to complete transport', error);
    } finally {
      this.completing.set(false);
    }
  }
}
