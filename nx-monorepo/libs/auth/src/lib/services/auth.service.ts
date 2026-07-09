import { Injectable, signal } from '@angular/core';
import {
  Auth,
  User,
  getAuth,
  onAuthStateChanged,
  sendPasswordResetEmail,
  signInWithEmailAndPassword,
  signOut,
} from 'firebase/auth';
import { getFirebaseApp } from '../firebase-app';

@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly auth: Auth = getAuth(getFirebaseApp());

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

  async signIn(email: string, password: string): Promise<void> {
    await signInWithEmailAndPassword(this.auth, email, password);
  }

  async signOut(): Promise<void> {
    await signOut(this.auth);
  }

  async resetPassword(email: string): Promise<void> {
    await sendPasswordResetEmail(this.auth, email);
  }
}
