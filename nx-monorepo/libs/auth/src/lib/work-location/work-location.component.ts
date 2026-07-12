import { Component, computed, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { AbstractControl, FormControl, ReactiveFormsModule, ValidationErrors, Validators } from '@angular/forms';
import { Router } from '@angular/router';
import { MatAutocompleteModule } from '@angular/material/autocomplete';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { HOSPITAL_NAMES } from '../hospitals';
import { UserProfileService } from '../services/user-profile.service';

// mat-autocomplete doesn't itself constrain the input to one of its options
// (it's just a suggestion dropdown over a free-text input) — this rejects
// anything the user types or leaves that isn't an exact match.
function hospitalNameValidator(control: AbstractControl): ValidationErrors | null {
  return HOSPITAL_NAMES.includes(control.value) ? null : { unknownHospital: true };
}

@Component({
  selector: 'lib-work-location',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule, MatAutocompleteModule, MatButtonModule, MatFormFieldModule, MatInputModule],
  templateUrl: './work-location.component.html',
  styleUrls: ['./work-location.component.scss'],
})
export class WorkLocationComponent {
  private readonly userProfileService = inject(UserProfileService);
  private readonly router = inject(Router);

  readonly submitting = signal(false);
  readonly errorMessage = signal<string | null>(null);

  readonly hospitalControl = new FormControl('', {
    nonNullable: true,
    validators: [Validators.required, hospitalNameValidator],
  });

  private readonly typedValue = signal('');

  readonly filteredHospitals = computed(() => {
    const query = this.typedValue().trim().toLowerCase();
    return query ? HOSPITAL_NAMES.filter((name) => name.toLowerCase().includes(query)) : HOSPITAL_NAMES;
  });

  constructor() {
    this.hospitalControl.valueChanges.subscribe((value) => this.typedValue.set(value ?? ''));
  }

  async onSubmit() {
    if (this.hospitalControl.invalid) {
      this.hospitalControl.markAsTouched();
      return;
    }

    this.submitting.set(true);
    this.errorMessage.set(null);

    try {
      await this.userProfileService.saveWorkLocation(this.hospitalControl.value);
      this.router.navigateByUrl('/');
    } catch (error) {
      this.errorMessage.set('Failed to save your work location. Please try again.');
      console.error('Failed to save work location', error);
    } finally {
      this.submitting.set(false);
    }
  }
}
