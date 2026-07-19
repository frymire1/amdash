import { Component, computed, effect, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { AbstractControl, FormBuilder, ReactiveFormsModule, ValidationErrors, Validators } from '@angular/forms';
import { Router } from '@angular/router';
import { MatAutocompleteModule } from '@angular/material/autocomplete';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { HospitalService } from '../hospitals';
import { UserProfileService } from '../services/user-profile.service';

@Component({
  selector: 'lib-user-settings',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule, MatAutocompleteModule, MatButtonModule, MatFormFieldModule, MatInputModule],
  templateUrl: './user-settings.component.html',
  styleUrls: ['./user-settings.component.scss'],
})
export class UserSettingsComponent {
  private readonly formBuilder = inject(FormBuilder);
  private readonly userProfileService = inject(UserProfileService);
  private readonly hospitalService = inject(HospitalService);
  private readonly router = inject(Router);

  readonly submitting = signal(false);
  readonly errorMessage = signal<string | null>(null);

  // Only physician/nurse accounts have a work location (see workLocationGuard).
  readonly showHospitalField = computed(() => {
    const roles = this.userProfileService.profile()?.role ?? [];
    return roles.includes('physician') || roles.includes('nurse');
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
      await this.userProfileService.saveProfile(firstName, lastName);
      // Optional here — picking a hospital for the first time is handled by
      // the mandatory /work-location step (workLocationGuard); this field is
      // just for changing an already-set one later.
      if (hospital) {
        await this.userProfileService.saveWorkLocation(hospital);
      }
      this.router.navigateByUrl('/');
    } catch (error) {
      this.errorMessage.set('Failed to save your details. Please try again.');
      console.error('Failed to save profile', error);
    } finally {
      this.submitting.set(false);
    }
  }
}
