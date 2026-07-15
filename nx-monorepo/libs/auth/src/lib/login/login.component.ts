import { Component, computed, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { Router } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { FirebaseError } from 'firebase/app';
import { AuthService } from '../services/auth.service';
import { UserProfileService } from '../services/user-profile.service';

type LoginStep = 'email' | 'set-password' | 'sign-in';

@Component({
  selector: 'lib-login',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule, MatButtonModule, MatFormFieldModule, MatInputModule],
  templateUrl: './login.component.html',
  styleUrls: ['./login.component.scss'],
})
export class LoginComponent {
  private readonly formBuilder = inject(FormBuilder);
  private readonly authService = inject(AuthService);
  private readonly userProfileService = inject(UserProfileService);
  private readonly router = inject(Router);

  readonly step = signal<LoginStep>('email');
  readonly email = signal('');
  // Whether the email step found an existing (passwordless) account, vs. no
  // account at all — only changes the wording shown on the set-password
  // step, not its behavior.
  readonly accountExists = signal(false);

  readonly submitting = signal(false);
  readonly errorMessage = signal<string | null>(null);
  readonly resetSubmitting = signal(false);
  readonly resetMessage = signal<string | null>(null);

  readonly emailForm = this.formBuilder.nonNullable.group({
    email: ['', [Validators.required, Validators.email]],
  });

  readonly setPasswordForm = this.formBuilder.nonNullable.group({
    password: ['', Validators.required],
    confirmPassword: ['', Validators.required],
  });

  readonly signInForm = this.formBuilder.nonNullable.group({
    password: ['', Validators.required],
  });

  private readonly password = signal('');
  private readonly confirmPassword = signal('');

  readonly hasMinLength = computed(() => this.password().length >= 8);
  readonly hasUppercase = computed(() => /[A-Z]/.test(this.password()));
  readonly hasNumber = computed(() => /[0-9]/.test(this.password()));
  readonly hasSpecialChar = computed(() => /[^A-Za-z0-9]/.test(this.password()));
  readonly passwordsMatch = computed(() => {
    const confirm = this.confirmPassword();
    return confirm.length > 0 && this.password() === confirm;
  });
  // Deliberately excludes passwordsMatch — that has its own separate
  // match/mismatch message, so it shouldn't also keep this hint list (and
  // its wrapping element) around once the password itself is strong enough.
  readonly meetsPasswordStrength = computed(
    () => this.hasMinLength() && this.hasUppercase() && this.hasNumber() && this.hasSpecialChar(),
  );
  readonly allRequirementsMet = computed(() => this.meetsPasswordStrength() && this.passwordsMatch());

  constructor() {
    this.setPasswordForm.controls.password.valueChanges.subscribe((value) => this.password.set(value));
    this.setPasswordForm.controls.confirmPassword.valueChanges.subscribe((value) => this.confirmPassword.set(value));
  }

  async onSubmitEmail() {
    if (this.emailForm.invalid) {
      this.emailForm.markAllAsTouched();
      return;
    }

    const email = this.emailForm.controls.email.value;

    this.submitting.set(true);
    this.errorMessage.set(null);

    try {
      const status = await this.authService.checkAccountStatus(email);
      this.email.set(email);

      if (status.exists && status.hasPassword) {
        this.step.set('sign-in');
      } else {
        this.accountExists.set(status.exists);
        this.step.set('set-password');
      }
    } catch (error) {
      this.errorMessage.set('Something went wrong. Please try again.');
      console.error('Failed to check account status', error);
    } finally {
      this.submitting.set(false);
    }
  }

  async onSubmitSetPassword() {
    if (!this.allRequirementsMet()) {
      this.setPasswordForm.markAllAsTouched();
      return;
    }

    const email = this.email();
    const password = this.setPasswordForm.controls.password.value;

    this.submitting.set(true);
    this.errorMessage.set(null);

    try {
      if (this.accountExists()) {
        await this.authService.claimPasswordlessAccount(email, password);
      } else {
        const user = await this.authService.signUp(email, password);
        await this.userProfileService.initializeProfile(user.uid, email);
      }
      this.router.navigateByUrl('/');
    } catch (error) {
      // Rare race: checkAccountStatus said no account existed, but one was
      // created (e.g. by an admin) in the moment before this submit. Fall
      // back to claiming it with the password they just chose rather than
      // just failing.
      if (!this.accountExists() && error instanceof FirebaseError && error.code === 'auth/email-already-in-use') {
        try {
          await this.authService.claimPasswordlessAccount(email, password);
          this.router.navigateByUrl('/');
          return;
        } catch (claimError) {
          console.error('Failed to claim account after race', claimError);
        }
      }
      this.errorMessage.set('Could not set your password. Please try again.');
      console.error('Failed to set password', error);
    } finally {
      this.submitting.set(false);
    }
  }

  async onSubmitSignIn() {
    if (this.signInForm.invalid) {
      this.signInForm.markAllAsTouched();
      return;
    }

    const password = this.signInForm.controls.password.value;

    this.submitting.set(true);
    this.errorMessage.set(null);

    try {
      await this.authService.signIn(this.email(), password);
      this.router.navigateByUrl('/');
    } catch (error) {
      this.errorMessage.set('Invalid email or password.');
      console.error('Failed to sign in', error);
    } finally {
      this.submitting.set(false);
    }
  }

  useAnotherEmail() {
    this.step.set('email');
    this.errorMessage.set(null);
    this.resetMessage.set(null);
    this.setPasswordForm.reset();
    this.signInForm.reset();
  }

  async onForgotPassword() {
    this.resetSubmitting.set(true);
    this.errorMessage.set(null);
    this.resetMessage.set(null);

    try {
      await this.authService.resetPassword(this.email());
      this.resetMessage.set('Password reset email sent — check your inbox.');
    } catch (error) {
      this.errorMessage.set('Could not send a reset email for that address.');
      console.error('Failed to send password reset email', error);
    } finally {
      this.resetSubmitting.set(false);
    }
  }
}
