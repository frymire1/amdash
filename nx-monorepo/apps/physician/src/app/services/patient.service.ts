import { Injectable, effect, inject, signal } from '@angular/core';
import { Unsubscribe, collection, getFirestore, onSnapshot, orderBy, query, where } from 'firebase/firestore';
import { getFirebaseApp } from '../firebase';
import { Patient } from '@amdash/patients';
import { UserProfileService } from '@amdash/auth';

@Injectable({ providedIn: 'root' })
export class PatientService {
  private readonly firestore = getFirestore(getFirebaseApp());
  private readonly userProfileService = inject(UserProfileService);

  readonly patients = signal<Patient[]>([]);

  private unsubscribe: Unsubscribe | undefined;

  constructor() {
    // Re-subscribes whenever the signed-in user's own profile changes —
    // the query itself depends on organizationId, which isn't known until
    // the profile has loaded.
    effect(() => {
      const organizationId = this.userProfileService.profile()?.organizationId;

      this.unsubscribe?.();
      this.unsubscribe = undefined;

      if (!organizationId) {
        this.patients.set([]);
        return;
      }

      const patientsQuery = query(
        collection(this.firestore, 'patients'),
        where('organizationId', '==', organizationId),
        where('status', '==', 'active'),
        orderBy('submittedAt', 'desc'),
      );
      this.unsubscribe = onSnapshot(patientsQuery, (snapshot) => {
        this.patients.set(
          snapshot.docs.map((docSnapshot) => ({ id: docSnapshot.id, ...(docSnapshot.data() as Patient) })),
        );
      });
    });
  }
}
