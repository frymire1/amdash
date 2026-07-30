import { Injectable, effect, inject, signal } from '@angular/core';
import { Unsubscribe, collection, getFirestore, onSnapshot, orderBy, query, where } from 'firebase/firestore';
import { getFirebaseApp } from '../firebase';
import { Patient } from '@amdash/patients';
import { UploadedPatient } from '../classes/uploaded-patient';
import { UserProfileService } from '@amdash/auth';

@Injectable({ providedIn: 'root' })
export class PatientSessionService {
  private readonly firestore = getFirestore(getFirebaseApp());
  private readonly userProfileService = inject(UserProfileService);

  readonly uploadedPatients = signal<UploadedPatient[]>([]);

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
        this.uploadedPatients.set([]);
        return;
      }

      const patientsQuery = query(
        collection(this.firestore, 'patients'),
        where('organizationId', '==', organizationId),
        orderBy('submittedAt', 'desc'),
      );
      this.unsubscribe = onSnapshot(patientsQuery, (snapshot) => {
        this.uploadedPatients.set(
          snapshot.docs.map((docSnapshot) => ({
            id: docSnapshot.id,
            patient: docSnapshot.data() as Patient,
          })),
        );
      });
    });
  }

  findUploadedPatient(id: string): UploadedPatient | undefined {
    return this.uploadedPatients().find((uploaded) => uploaded.id === id);
  }
}
