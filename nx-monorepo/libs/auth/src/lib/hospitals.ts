import { Injectable, effect, inject, signal, computed } from '@angular/core';
import { Unsubscribe, collection, getFirestore, onSnapshot, orderBy, query, where } from 'firebase/firestore';
import { getFirebaseApp } from './firebase-app';
import { Hospital } from './classes/hospital';
import { UserProfileService } from './services/user-profile.service';

// Hospitals live in Firestore now (managed by admins via the admin app's
// Hospitals page — see createHospital/deleteHospital in functions/src) —
// this replaces what used to be a hardcoded array. Read-only here: writes
// only ever happen through those Cloud Functions, since creating a hospital
// requires geocoding its address server-side.
@Injectable({ providedIn: 'root' })
export class HospitalService {
  private readonly firestore = getFirestore(getFirebaseApp());
  private readonly userProfileService = inject(UserProfileService);

  readonly hospitals = signal<Hospital[]>([]);
  readonly hospitalNames = computed(() => this.hospitals().map((hospital) => hospital.name));

  private unsubscribe: Unsubscribe | undefined;

  constructor() {
    // Re-subscribes whenever the signed-in user's own profile changes —
    // needed because which query is legal depends on it: a super-admin's
    // profile has no organizationId at all (see UserProfile's comment) and,
    // per the confirmed product decision, gets full cross-org visibility, so
    // this is the one hospital query in the app that stays unconstrained for
    // that role. Every other role must filter by its own org, or
    // firestore.rules's sameOrgAsCaller rejects the whole list request.
    effect(() => {
      const profile = this.userProfileService.profile();

      this.unsubscribe?.();
      this.unsubscribe = undefined;

      const isSuperAdmin = profile?.role?.includes('super-admin') ?? false;

      // A non-super-admin with no organizationId yet (profile still loading,
      // or an incomplete/malformed doc) has no valid scope to query with —
      // where() rejects `undefined` outright, so this stays empty rather
      // than attempting an invalid query.
      if (!profile || (!isSuperAdmin && !profile.organizationId)) {
        this.hospitals.set([]);
        return;
      }

      const hospitalsQuery = isSuperAdmin
        ? query(collection(this.firestore, 'hospitals'), orderBy('name'))
        : query(
            collection(this.firestore, 'hospitals'),
            where('organizationId', '==', profile.organizationId),
            orderBy('name'),
          );

      this.unsubscribe = onSnapshot(hospitalsQuery, (snapshot) => {
        this.hospitals.set(
          snapshot.docs.map((docSnapshot) => ({ id: docSnapshot.id, ...(docSnapshot.data() as Omit<Hospital, 'id'>) })),
        );
      });
    });
  }

  findHospital(name: string | undefined): Hospital | undefined {
    return this.hospitals().find((hospital) => hospital.name === name);
  }
}
