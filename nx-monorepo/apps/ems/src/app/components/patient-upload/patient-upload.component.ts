import { Component, effect, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, Router } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatDialog } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MatSelectModule } from '@angular/material/select';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { HospitalService, TimeoutError, withTimeout } from '@amdash/auth';
import { Patient } from '@amdash/patients';
import { PatientUploadService } from '../../services/patient-upload.service';
import { PatientSessionService } from '../../services/patient-session.service';
import { EmsTrackingService } from '../../services/ems-tracking.service';
import { ErrorDialogComponent } from '../error-dialog/error-dialog.component';

function toNumberOrNull(value: number | string | undefined): number | null {
  return typeof value === 'number' ? value : null;
}

// Standard peripheral IV catheter gauges, largest (trauma) to smallest
// (pediatric/fragile veins).
export const IV_SIZES: readonly string[] = ['14G', '16G', '18G', '20G', '22G', '24G'];

export const IV_PLACEMENTS: readonly string[] = [
  'Left Hand',
  'Right Hand',
  'Left Forearm',
  'Right Forearm',
  'Left Antecubital (AC)',
  'Right Antecubital (AC)',
  'External Jugular (EJ)',
  'Other',
];

@Component({
  selector: 'app-patient-upload',
  standalone: true,
  imports: [
    CommonModule,
    ReactiveFormsModule,
    MatButtonModule,
    MatFormFieldModule,
    MatIconModule,
    MatInputModule,
    MatProgressSpinnerModule,
    MatSelectModule,
    MatSlideToggleModule,
  ],
  templateUrl: './patient-upload.component.html',
  styleUrls: ['./patient-upload.component.scss'],
})
export class PatientUploadComponent {
  private readonly formBuilder = inject(FormBuilder);
  private readonly patientUploadService = inject(PatientUploadService);
  private readonly patientSessionService = inject(PatientSessionService);
  private readonly trackingService = inject(EmsTrackingService);
  private readonly hospitalService = inject(HospitalService);
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);
  private readonly dialog = inject(MatDialog);

  private editingId: string | null = null;
  private formPrefilled = false;

  readonly destinationHospitals = this.hospitalService.hospitalNames;
  readonly ivSizes = IV_SIZES;
  readonly ivPlacements = IV_PLACEMENTS;

  readonly isEditing = signal(false);
  readonly submitting = signal(false);
  readonly errorMessage = signal<string | null>(null);
  readonly locatingDevice = signal(false);
  readonly locationError = signal<string | null>(null);
  readonly locationShared = signal(false);
  readonly liveTrackingEnabled = signal(true);

  readonly patientForm = this.formBuilder.nonNullable.group({
    name: [''],
    gender: [''],
    age: [null as number | null, Validators.min(0)],
    healthcareNumber: [''],
    destination: [''],
    vitals: this.formBuilder.nonNullable.group({
      heartRate: [null as number | null],
      bloodPressure: [''],
      oxygen: [null as number | null],
      temperature: [null as number | null],
      respiratoryRate: [null as number | null, Validators.min(0)],
      gcs: [null as number | null, [Validators.min(3), Validators.max(15)]],
    }),
    // Every field, including location, is optional — this is only
    // best-effort auto-populated from the device's geolocation (see
    // useCurrentLocation below) rather than manually entered, and a denied
    // or unavailable permission shouldn't block submitting the rest of the
    // form.
    location: this.formBuilder.nonNullable.group({
      latitude: [null as number | null],
      longitude: [null as number | null],
    }),
    ivSize: [''],
    ivPlacement: [''],
    treatment: [''],
    notes: [''],
  });

  constructor() {
    const id = this.route.snapshot.paramMap.get('id');

    if (id) {
      this.editingId = id;
      this.isEditing.set(true);
      this.liveTrackingEnabled.set(this.trackingService.isTracking(id));

      // The patient list is loaded asynchronously from Firestore, so keep
      // watching until the record we're editing shows up (e.g. on a direct
      // reload of /upload/:id before the initial snapshot has arrived).
      effect(() => {
        if (this.formPrefilled) {
          return;
        }

        const uploaded = this.patientSessionService.findUploadedPatient(id);
        if (!uploaded) {
          return;
        }

        this.formPrefilled = true;
        this.patientForm.setValue({
          name: uploaded.patient.name,
          gender: uploaded.patient.gender,
          age: toNumberOrNull(uploaded.patient.age),
          healthcareNumber: uploaded.patient.healthcareNumber,
          destination: uploaded.patient.destination ?? '',
          vitals: {
            heartRate: toNumberOrNull(uploaded.patient.vitals.heartRate),
            bloodPressure: uploaded.patient.vitals.bloodPressure,
            oxygen: toNumberOrNull(uploaded.patient.vitals.oxygen),
            temperature: toNumberOrNull(uploaded.patient.vitals.temperature),
            respiratoryRate: uploaded.patient.vitals.respiratoryRate ?? null,
            gcs: uploaded.patient.vitals.gcs ?? null,
          },
          location: {
            latitude: uploaded.patient.location?.latitude ?? null,
            longitude: uploaded.patient.location?.longitude ?? null,
          },
          ivSize: uploaded.patient.ivSize ?? '',
          ivPlacement: uploaded.patient.ivPlacement ?? '',
          treatment: uploaded.patient.treatment ?? '',
          notes: uploaded.patient.notes ?? '',
        });
        // Only claim location is already shared if this patient actually
        // has one on record — it's optional now, so an edited patient may
        // never have had one (e.g. geolocation was denied on upload).
        this.locationShared.set(!!uploaded.patient.location);
      });
    } else {
      this.useCurrentLocation();
    }
  }

  private useCurrentLocation() {
    if (!('geolocation' in navigator)) {
      this.locationError.set('Geolocation is not supported by this browser.');
      return;
    }

    this.locatingDevice.set(true);
    this.locationError.set(null);

    navigator.geolocation.getCurrentPosition(
      (position) => {
        this.patientForm.controls.location.patchValue({
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
        });
        this.locationShared.set(true);
        this.locatingDevice.set(false);
      },
      (error) => {
        this.locationShared.set(false);
        this.locationError.set(
          'Could not get your current location. Please allow location access and try again.',
        );
        console.error('Failed to get current location', error);
        this.locatingDevice.set(false);
      },
      { enableHighAccuracy: true, timeout: 10000 },
    );
  }

  async onSubmit() {
    if (this.patientForm.invalid) {
      this.patientForm.markAllAsTouched();
      return;
    }

    const value = this.patientForm.getRawValue();
    const hasLocation = value.location.latitude != null && value.location.longitude != null;

    // Firestore's JS SDK rejects a literal `undefined` field value outright
    // (addDoc/updateDoc throw), so optional fields left empty are omitted
    // via spread here rather than assigned `undefined` directly.
    const patient: Patient = {
      name: value.name || 'Unknown',
      gender: value.gender || 'Unknown',
      age: value.age ?? 'Unknown',
      healthcareNumber: value.healthcareNumber || 'Unknown',
      destination: value.destination || 'Unknown',
      vitals: {
        heartRate: value.vitals.heartRate ?? 'Unknown',
        bloodPressure: value.vitals.bloodPressure || 'Unknown',
        oxygen: value.vitals.oxygen ?? 'Unknown',
        temperature: value.vitals.temperature ?? 'Unknown',
        ...(value.vitals.respiratoryRate != null ? { respiratoryRate: value.vitals.respiratoryRate } : {}),
        ...(value.vitals.gcs != null ? { gcs: value.vitals.gcs } : {}),
      },
      ...(hasLocation
        ? {
            location: {
              latitude: value.location.latitude as number,
              longitude: value.location.longitude as number,
              address: '',
            },
          }
        : {}),
      ...(value.ivSize ? { ivSize: value.ivSize } : {}),
      ...(value.ivPlacement ? { ivPlacement: value.ivPlacement } : {}),
      ...(value.treatment ? { treatment: value.treatment } : {}),
      notes: value.notes,
    };

    this.submitting.set(true);
    this.errorMessage.set(null);

    let id: string;
    try {
      // Firestore never rejects a write blocked by a dropped connection —
      // it retries indefinitely instead — so this bounds how long the user
      // waits before seeing an error rather than a spinner stuck forever.
      // The underlying write isn't cancelled, and may still complete in the
      // background afterward.
      if (this.editingId) {
        id = this.editingId;
        await withTimeout(this.patientUploadService.updatePatient(id, patient));
      } else {
        id = await withTimeout(this.patientUploadService.uploadPatient(patient));
        // If live tracking below fails, the user stays on this page to
        // retry rather than being navigated away — treat the patient as
        // already-created from here on so a retry updates it instead of
        // creating a duplicate.
        this.editingId = id;
        this.isEditing.set(true);
      }
    } catch (error) {
      this.errorMessage.set(
        error instanceof TimeoutError
          ? 'This is taking longer than expected. Check your connection and try again.'
          : 'Failed to upload patient. Please try again.',
      );
      console.error('Failed to upload patient', error);
      this.submitting.set(false);
      return;
    }

    try {
      if (this.liveTrackingEnabled()) {
        // Awaited so the button's spinner stays up until live tracking is
        // actually confirmed started, not just requested.
        await this.trackingService.startTracking(id);
      } else {
        this.trackingService.stopTracking(id);
      }

      this.router.navigate(['/']);
    } catch (error) {
      console.error('Failed to start live tracking', error);
      this.dialog.open(ErrorDialogComponent, {
        data: {
          title: 'Live tracking failed',
          message:
            'The patient was saved, but live tracking could not be started. Please check that location permission is enabled for this site, then try again from this page.',
        },
      });
    } finally {
      this.submitting.set(false);
    }
  }
}
