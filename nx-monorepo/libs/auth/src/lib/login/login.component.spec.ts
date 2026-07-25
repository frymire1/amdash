import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';

import { LoginComponent } from './login.component';
import { AuthService } from '../services/auth.service';

describe('LoginComponent', () => {
  let component: LoginComponent;
  let fixture: ComponentFixture<LoginComponent>;
  let checkAccountStatusResult: { exists: boolean; hasPassword: boolean };
  let signInCalled = false;
  let claimPasswordlessAccountCalled = false;
  let resetPasswordEmail: string | null = null;

  beforeEach(async () => {
    checkAccountStatusResult = { exists: true, hasPassword: true };
    signInCalled = false;
    claimPasswordlessAccountCalled = false;
    resetPasswordEmail = null;

    await TestBed.configureTestingModule({
      imports: [LoginComponent],
      providers: [
        provideRouter([]),
        {
          provide: AuthService,
          useValue: {
            checkAccountStatus: async () => checkAccountStatusResult,
            signIn: async () => {
              signInCalled = true;
            },
            claimPasswordlessAccount: async () => {
              claimPasswordlessAccountCalled = true;
            },
            resetPassword: async (email: string) => {
              resetPasswordEmail = email;
            },
          },
        },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(LoginComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('should not check account status for an invalid email', async () => {
    await component.onSubmitEmail();
    expect(component.step()).toBe('email');
    expect(component.emailForm.touched).toBe(true);
  });

  it('moves to the not-activated step for an email with no account', async () => {
    checkAccountStatusResult = { exists: false, hasPassword: false };
    component.emailForm.controls.email.setValue('nobody@amdash.dev');

    await component.onSubmitEmail();

    expect(component.step()).toBe('not-activated');
  });

  it('moves to the sign-in step for an existing account with a password', async () => {
    checkAccountStatusResult = { exists: true, hasPassword: true };
    component.emailForm.controls.email.setValue('demo@amdash.dev');

    await component.onSubmitEmail();

    expect(component.step()).toBe('sign-in');
  });

  it('moves to the set-password step for an admin-created account with no password yet', async () => {
    checkAccountStatusResult = { exists: true, hasPassword: false };
    component.emailForm.controls.email.setValue('invited@amdash.dev');

    await component.onSubmitEmail();

    expect(component.step()).toBe('set-password');
  });

  it('should not sign in with an empty password', async () => {
    await component.onSubmitSignIn();
    expect(signInCalled).toBe(false);
    expect(component.signInForm.touched).toBe(true);
  });

  it('signs in with a valid password', async () => {
    component.signInForm.controls.password.setValue('demo1234');

    await component.onSubmitSignIn();

    expect(signInCalled).toBe(true);
  });

  it('does not claim a passwordless account until every password requirement is met', async () => {
    component.setPasswordForm.setValue({ password: 'short', confirmPassword: 'short' });

    await component.onSubmitSetPassword();

    expect(claimPasswordlessAccountCalled).toBe(false);
  });

  it('claims a passwordless account once every password requirement is met', async () => {
    component.setPasswordForm.setValue({ password: 'Demo1234!', confirmPassword: 'Demo1234!' });

    await component.onSubmitSetPassword();

    expect(claimPasswordlessAccountCalled).toBe(true);
  });

  it('sends a reset email for the current step email', async () => {
    checkAccountStatusResult = { exists: true, hasPassword: true };
    component.emailForm.controls.email.setValue('demo@amdash.dev');
    await component.onSubmitEmail();

    await component.onForgotPassword();

    expect(resetPasswordEmail).toBe('demo@amdash.dev');
    expect(component.resetMessage()).toContain('Password reset email sent');
  });
});
