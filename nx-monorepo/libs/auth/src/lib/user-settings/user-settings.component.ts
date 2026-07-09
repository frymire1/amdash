import { Component, effect, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { Router } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { UserProfileService } from '../services/user-profile.service';

@Component({
  selector: 'lib-user-settings',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule, MatButtonModule, MatFormFieldModule, MatInputModule],
  templateUrl: './user-settings.component.html',
  styleUrls: ['./user-settings.component.scss'],
})
export class UserSettingsComponent {
  private readonly formBuilder = inject(FormBuilder);
  private readonly userProfileService = inject(UserProfileService);
  private readonly router = inject(Router);

  readonly submitting = signal(false);
  readonly errorMessage = signal<string | null>(null);

  readonly settingsForm = this.formBuilder.nonNullable.group({
    firstName: ['', Validators.required],
    lastName: ['', Validators.required],
  });

  constructor() {
    effect(() => {
      const profile = this.userProfileService.profile();
      if (profile) {
        this.settingsForm.patchValue({
          firstName: profile.firstName,
          lastName: profile.lastName,
        });
      }
    });
  }

  async onSubmit() {
    if (this.settingsForm.invalid) {
      this.settingsForm.markAllAsTouched();
      return;
    }

    const { firstName, lastName } = this.settingsForm.getRawValue();

    this.submitting.set(true);
    this.errorMessage.set(null);

    try {
      await this.userProfileService.saveProfile(firstName, lastName);
      this.router.navigateByUrl('/');
    } catch (error) {
      this.errorMessage.set('Failed to save your details. Please try again.');
      console.error('Failed to save profile', error);
    } finally {
      this.submitting.set(false);
    }
  }
}
