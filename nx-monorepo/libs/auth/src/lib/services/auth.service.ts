import { Injectable, signal } from '@angular/core';
import {
  Auth,
  User,
  createUserWithEmailAndPassword,
  getAuth,
  onAuthStateChanged,
  sendPasswordResetEmail,
  signInWithEmailAndPassword,
  signOut,
} from 'firebase/auth';
import { getFunctions, httpsCallable } from 'firebase/functions';
import { getFirebaseApp } from '../firebase-app';

const FUNCTIONS_REGION = 'northamerica-northeast2';

interface SetInitialPasswordRequest {
  email: string;
  password: string;
}

interface SetInitialPasswordResponse {
  email: string;
}

interface CheckAccountStatusRequest {
  email: string;
}

export interface AccountStatus {
  exists: boolean;
  hasPassword: boolean;
}

@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly auth: Auth = getAuth(getFirebaseApp());
  private readonly functions = getFunctions(getFirebaseApp(), FUNCTIONS_REGION);
  private readonly setInitialPasswordFn = httpsCallable<SetInitialPasswordRequest, SetInitialPasswordResponse>(
    this.functions,
    'setInitialPassword',
  );
  private readonly checkAccountStatusFn = httpsCallable<CheckAccountStatusRequest, AccountStatus>(
    this.functions,
    'checkAccountStatus',
  );

  readonly user = signal<User | null>(null);
  readonly initializing = signal(true);

  constructor() {
    onAuthStateChanged(this.auth, (user) => {
      this.user.set(user);
      this.initializing.set(false);
    });
  }

  isAuthenticated(): boolean {
    return this.user() !== null;
  }

  // Drives the login page's email-first flow: whether to show a
  // set-your-password screen (no account, or an admin-created account with
  // no password yet) or a normal single-password sign-in screen.
  async checkAccountStatus(email: string): Promise<AccountStatus> {
    const result = await this.checkAccountStatusFn({ email });
    return result.data;
  }

  async signIn(email: string, password: string): Promise<void> {
    await signInWithEmailAndPassword(this.auth, email, password);
  }

  async signUp(email: string, password: string): Promise<User> {
    const credential = await createUserWithEmailAndPassword(this.auth, email, password);
    return credential.user;
  }

  async signOut(): Promise<void> {
    await signOut(this.auth);
  }

  async resetPassword(email: string): Promise<void> {
    await sendPasswordResetEmail(this.auth, email);
  }

  // For an account an admin created (email only, no password) — sets that
  // password server-side (see setInitialPassword in functions/src/index.ts,
  // which refuses to touch an account that already has one) and signs in
  // with it. Callers should only reach for this after a normal signUp()
  // fails with auth/email-already-in-use.
  async claimPasswordlessAccount(email: string, password: string): Promise<void> {
    await this.setInitialPasswordFn({ email, password });
    await this.signIn(email, password);
  }
}
