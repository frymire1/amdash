import { Injectable, computed, effect, inject, signal } from '@angular/core';
import { doc, getDoc, getFirestore, setDoc } from 'firebase/firestore';
import { getFirebaseApp } from '../firebase-app';
import { AuthService } from './auth.service';

export interface UserProfile {
  firstName: string;
  lastName: string;
}

@Injectable({ providedIn: 'root' })
export class UserProfileService {
  private readonly firestore = getFirestore(getFirebaseApp());
  private readonly authService = inject(AuthService);

  readonly profile = signal<UserProfile | null>(null);
  readonly loading = signal(true);

  readonly initials = computed(() => {
    const profile = this.profile();
    if (!profile) {
      return '';
    }
    return `${profile.firstName.charAt(0)}${profile.lastName.charAt(0)}`.toUpperCase();
  });

  constructor() {
    effect(() => {
      // Firebase Auth's initial session check is always async. Until it
      // resolves, `user()` is just its unset default (null) — not yet a
      // reliable "logged out" signal — so wait rather than act on it.
      if (this.authService.initializing()) {
        return;
      }

      const user = this.authService.user();

      if (!user) {
        this.profile.set(null);
        this.loading.set(false);
        return;
      }

      this.loading.set(true);
      getDoc(doc(this.firestore, 'users', user.uid))
        .then((snapshot) => {
          this.profile.set(snapshot.exists() ? (snapshot.data() as UserProfile) : null);
        })
        .catch((error) => {
          console.error('Failed to load user profile', error);
          this.profile.set(null);
        })
        .finally(() => {
          this.loading.set(false);
        });
    });
  }

  async saveProfile(firstName: string, lastName: string): Promise<void> {
    const user = this.authService.user();
    if (!user) {
      throw new Error('Cannot save a profile without an authenticated user.');
    }

    const profile: UserProfile = { firstName, lastName };
    await setDoc(doc(this.firestore, 'users', user.uid), profile);
    this.profile.set(profile);
  }
}
