import { Component, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { Router } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { FirebaseError } from 'firebase/app';
import { AuthService } from '../services/auth.service';
import { UserProfileService } from '../services/user-profile.service';

type LoginMode = 'signin' | 'signup';

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

  readonly mode = signal<LoginMode>('signin');
  readonly submitting = signal(false);
  readonly errorMessage = signal<string | null>(null);
  readonly resetSubmitting = signal(false);
  readonly resetMessage = signal<string | null>(null);

  readonly loginForm = this.formBuilder.nonNullable.group({
    email: ['', [Validators.required, Validators.email]],
    password: ['', Validators.required],
  });

  toggleMode() {
    this.mode.update((mode) => (mode === 'signin' ? 'signup' : 'signin'));
    this.errorMessage.set(null);
    this.resetMessage.set(null);
  }

  async onSubmit() {
    if (this.loginForm.invalid) {
      this.loginForm.markAllAsTouched();
      return;
    }

    const { email, password } = this.loginForm.getRawValue();

    this.submitting.set(true);
    this.errorMessage.set(null);
    this.resetMessage.set(null);

    try {
      if (this.mode() === 'signup') {
        const user = await this.authService.signUp(email, password);
        await this.userProfileService.initializeProfile(user.uid, email);
      } else {
        await this.authService.signIn(email, password);
      }
      this.router.navigateByUrl('/');
    } catch (error) {
      if (this.mode() === 'signup' && error instanceof FirebaseError && error.code === 'auth/email-already-in-use') {
        this.errorMessage.set('An account with this email already exists. Try signing in instead.');
      } else {
        this.errorMessage.set(
          this.mode() === 'signup' ? 'Could not create an account with that email.' : 'Invalid email or password.',
        );
      }
      console.error(this.mode() === 'signup' ? 'Failed to sign up' : 'Failed to sign in', error);
    } finally {
      this.submitting.set(false);
    }
  }

  async onForgotPassword() {
    const emailControl = this.loginForm.controls.email;

    if (emailControl.invalid) {
      emailControl.markAsTouched();
      this.errorMessage.set('Enter your email above, then click "Forgot password?".');
      return;
    }

    this.resetSubmitting.set(true);
    this.errorMessage.set(null);
    this.resetMessage.set(null);

    try {
      await this.authService.resetPassword(emailControl.value);
      this.resetMessage.set('Password reset email sent — check your inbox.');
    } catch (error) {
      this.errorMessage.set('Could not send a reset email for that address.');
      console.error('Failed to send password reset email', error);
    } finally {
      this.resetSubmitting.set(false);
    }
  }
}
