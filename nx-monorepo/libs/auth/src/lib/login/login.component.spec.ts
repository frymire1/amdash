import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';

import { LoginComponent } from './login.component';
import { AuthService } from '../services/auth.service';
import { UserProfileService } from '../services/user-profile.service';

describe('LoginComponent', () => {
  let component: LoginComponent;
  let fixture: ComponentFixture<LoginComponent>;
  let signInCalled = false;
  let signUpCalled = false;
  let initializeProfileCalled = false;
  let resetPasswordEmail: string | null = null;

  beforeEach(async () => {
    signInCalled = false;
    signUpCalled = false;
    initializeProfileCalled = false;
    resetPasswordEmail = null;

    await TestBed.configureTestingModule({
      imports: [LoginComponent],
      providers: [
        provideRouter([]),
        {
          provide: AuthService,
          useValue: {
            signIn: async () => {
              signInCalled = true;
            },
            signUp: async () => {
              signUpCalled = true;
              return { uid: 'new-uid', email: 'new@amdash.dev' };
            },
            resetPassword: async (email: string) => {
              resetPasswordEmail = email;
            },
          },
        },
        {
          provide: UserProfileService,
          useValue: {
            initializeProfile: async () => {
              initializeProfileCalled = true;
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

  it('should not sign in with an invalid form', async () => {
    await component.onSubmit();
    expect(signInCalled).toBe(false);
    expect(component.loginForm.touched).toBe(true);
  });

  it('should not send a reset email without a valid email', async () => {
    await component.onForgotPassword();
    expect(resetPasswordEmail).toBeNull();
    expect(component.errorMessage()).toContain('Enter your email');
  });

  it('should send a reset email for a valid address', async () => {
    component.loginForm.controls.email.setValue('demo@amdash.dev');
    await component.onForgotPassword();
    expect(resetPasswordEmail).toBe('demo@amdash.dev');
    expect(component.resetMessage()).toContain('Password reset email sent');
  });

  it('creates an account and initializes its Firestore reference in signup mode', async () => {
    component.toggleMode();
    component.loginForm.setValue({ email: 'new@amdash.dev', password: 'demo1234' });

    await component.onSubmit();

    expect(signUpCalled).toBe(true);
    expect(initializeProfileCalled).toBe(true);
  });
});
