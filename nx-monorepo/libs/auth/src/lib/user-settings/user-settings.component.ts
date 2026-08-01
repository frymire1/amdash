import { Component, DestroyRef, computed, effect, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { AbstractControl, FormBuilder, ReactiveFormsModule, ValidationErrors, Validators } from '@angular/forms';
import { Router } from '@angular/router';
import { MatAutocompleteModule } from '@angular/material/autocomplete';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { HospitalService } from '../hospitals';
import { UserProfileService } from '../services/user-profile.service';
import { PatientAlertService } from '../services/patient-alert.service';
import { TimeoutError, withTimeout } from '../with-timeout';

@Component({
  selector: 'lib-user-settings',
  standalone: true,
  imports: [
    CommonModule,
    ReactiveFormsModule,
    MatAutocompleteModule,
    MatButtonModule,
    MatFormFieldModule,
    MatInputModule,
    MatSelectModule,
    MatProgressSpinnerModule,
  ],
  templateUrl: './user-settings.component.html',
  styleUrls: ['./user-settings.component.scss'],
})
export class UserSettingsComponent {
  private readonly formBuilder = inject(FormBuilder);
  private readonly userProfileService = inject(UserProfileService);
  private readonly hospitalService = inject(HospitalService);
  private readonly patientAlertService = inject(PatientAlertService);
  private readonly router = inject(Router);
  private readonly destroyRef = inject(DestroyRef);

  readonly submitting = signal(false);
  readonly errorMessage = signal<string | null>(null);

  // Only physician/nurse accounts have a work location (see workLocationGuard).
  readonly showHospitalField = computed(() => {
    const roles = this.userProfileService.profile()?.role ?? [];
    return roles.includes('physician') || roles.includes('nurse');
  });

  readonly alertHours = Array.from({ length: 12 }, (_, index) => index + 1);
  readonly selectedAlertHours = signal(4);
  readonly enablingAlerts = signal(false);
  readonly disablingAlerts = signal(false);
  readonly alertsBlockedMessage = signal<string | null>(null);

  // Ticks every 60s (matching EmsLocationService's own recheck-interval
  // pattern) purely so alertsExpiresAt below flips itself back to "off" once
  // the armed window elapses, with no reload needed.
  private readonly now = signal(Date.now());

  readonly alertsExpiresAt = computed(() => {
    this.now();
    const expiresAt = this.userProfileService.profile()?.newPatientAlertsExpiresAt;
    return expiresAt && expiresAt.toMillis() > Date.now() ? expiresAt : null;
  });

  // See work-location.component.ts's identical validator for why this
  // exists: mat-autocomplete alone doesn't constrain the input to one of its
  // options. Empty is allowed here (unlike work-location.component.ts) since
  // this field is only for changing an already-set hospital, not setting one.
  private readonly hospitalNameValidator = (control: AbstractControl): ValidationErrors | null => {
    return !control.value || this.hospitalService.hospitalNames().includes(control.value)
      ? null
      : { unknownHospital: true };
  };

  readonly settingsForm = this.formBuilder.nonNullable.group({
    firstName: ['', Validators.required],
    lastName: ['', Validators.required],
    hospital: ['', this.hospitalNameValidator],
  });

  private readonly typedHospital = signal('');

  readonly filteredHospitals = computed(() => {
    const query = this.typedHospital().trim().toLowerCase();
    const names = this.hospitalService.hospitalNames();
    return query ? names.filter((name) => name.toLowerCase().includes(query)) : names;
  });

  constructor() {
    this.settingsForm.controls.hospital.valueChanges.subscribe((value) => this.typedHospital.set(value ?? ''));

    effect(() => {
      const profile = this.userProfileService.profile();
      if (profile) {
        this.settingsForm.patchValue({
          firstName: profile.firstName,
          lastName: profile.lastName,
          hospital: profile.workLocation,
        });
      }
    });

    // The hospital list starts empty until the first Firestore snapshot
    // arrives — re-run validation once it loads, same as work-location.component.ts.
    effect(() => {
      this.hospitalService.hospitalNames();
      this.settingsForm.controls.hospital.updateValueAndValidity();
    });

    const intervalId = setInterval(() => this.now.set(Date.now()), 60000);
    this.destroyRef.onDestroy(() => clearInterval(intervalId));
  }

  async onEnableAlerts() {
    this.enablingAlerts.set(true);
    this.alertsBlockedMessage.set(null);

    try {
      const { granted } = await this.patientAlertService.enableAlerts(this.selectedAlertHours());
      if (!granted) {
        this.alertsBlockedMessage.set(
          "Notifications are blocked in your browser — enable them in your browser's site settings for AmDash to receive alerts.",
        );
      }
    } catch (error) {
      this.alertsBlockedMessage.set('Failed to enable alerts. Please try again.');
      console.error('Failed to enable new-patient alerts', error);
    } finally {
      this.enablingAlerts.set(false);
    }
  }

  async onDisableAlerts() {
    this.disablingAlerts.set(true);

    try {
      await this.patientAlertService.disableAlerts();
    } catch (error) {
      console.error('Failed to disable new-patient alerts', error);
    } finally {
      this.disablingAlerts.set(false);
    }
  }

  async onSubmit() {
    if (this.settingsForm.invalid) {
      this.settingsForm.markAllAsTouched();
      return;
    }

    const { firstName, lastName, hospital } = this.settingsForm.getRawValue();

    this.submitting.set(true);
    this.errorMessage.set(null);

    try {
      // Firestore never rejects a write blocked by a dropped connection —
      // it retries indefinitely instead — so this bounds how long the user
      // waits before seeing an error rather than a spinner stuck forever.
      // The underlying write isn't cancelled, and may still complete in the
      // background afterward.
      await withTimeout(this.userProfileService.saveProfile(firstName, lastName));
      // Optional here — picking a hospital for the first time is handled by
      // the mandatory /work-location step (workLocationGuard); this field is
      // just for changing an already-set one later.
      if (hospital) {
        await withTimeout(this.userProfileService.saveWorkLocation(hospital));
      }
      this.router.navigateByUrl('/');
    } catch (error) {
      this.errorMessage.set(
        error instanceof TimeoutError
          ? 'This is taking longer than expected. Check your connection and try again.'
          : 'Failed to save your details. Please try again.',
      );
      console.error('Failed to save profile', error);
    } finally {
      this.submitting.set(false);
    }
  }
}
