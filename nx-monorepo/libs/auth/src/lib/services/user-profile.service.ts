import { Injectable, computed, effect, inject, signal } from '@angular/core';
import { doc, getDoc, getFirestore, setDoc } from 'firebase/firestore';
import { getFirebaseApp } from '../firebase-app';
import { AuthService } from './auth.service';

export type UserRole = 'ems' | 'physician' | 'nurse' | 'admin';

export interface UserProfile {
  // Optional: a freshly signed-up account has a Firestore reference (just an
  // email) before it has completed the mandatory name onboarding step.
  firstName?: string;
  lastName?: string;
  // A user can hold more than one role at once (e.g. physician + admin).
  // Only ever set server-side (see setUserRole/removeUserRole in
  // functions/src/index.ts) — clients are blocked from touching this field.
  role?: UserRole[];
  // Hospital name (see @amdash/auth's HospitalService) a physician/nurse
  // works out of — mandatory for those roles (see workLocationGuard),
  // unused by ems/admin accounts.
  workLocation?: string;
}

@Injectable({ providedIn: 'root' })
export class UserProfileService {
  private readonly firestore = getFirestore(getFirebaseApp());
  private readonly authService = inject(AuthService);

  readonly profile = signal<UserProfile | null>(null);
  readonly loading = signal(true);

  readonly initials = computed(() => {
    const profile = this.profile();
    if (!profile?.firstName || !profile?.lastName) {
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

  // Called right after sign-up so a Firestore record exists for the new
  // account before the mandatory name onboarding step runs.
  async initializeProfile(uid: string, email: string): Promise<void> {
    await setDoc(doc(this.firestore, 'users', uid), { email }, { merge: true });
  }

  async saveProfile(firstName: string, lastName: string): Promise<void> {
    const user = this.authService.user();
    if (!user) {
      throw new Error('Cannot save a profile without an authenticated user.');
    }

    // Merge rather than overwrite so this never clobbers a `role` assigned
    // separately by an admin via the admin app / Cloud Function.
    await setDoc(doc(this.firestore, 'users', user.uid), { firstName, lastName }, { merge: true });

    // Re-read rather than locally splicing {...existing, firstName, lastName}
    // into the signal: `existing` can still be the constructor effect's
    // unset initial value (or a stale pre-role snapshot) if that effect's own
    // getDoc hasn't resolved yet by the time this runs, which would silently
    // drop fields like `role` from the cached profile for the rest of the
    // session.
    const freshSnapshot = await getDoc(doc(this.firestore, 'users', user.uid));
    this.profile.set(freshSnapshot.exists() ? (freshSnapshot.data() as UserProfile) : null);
  }

  async saveWorkLocation(workLocation: string): Promise<void> {
    const user = this.authService.user();
    if (!user) {
      throw new Error('Cannot save a work location without an authenticated user.');
    }

    await setDoc(doc(this.firestore, 'users', user.uid), { workLocation }, { merge: true });

    // See saveProfile() above for why this re-reads rather than locally
    // splicing the new field into the signal.
    const freshSnapshot = await getDoc(doc(this.firestore, 'users', user.uid));
    this.profile.set(freshSnapshot.exists() ? (freshSnapshot.data() as UserProfile) : null);
  }
}
