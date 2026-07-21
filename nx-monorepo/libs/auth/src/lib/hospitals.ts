import { Injectable, computed, signal } from '@angular/core';
import { collection, getFirestore, onSnapshot, orderBy, query } from 'firebase/firestore';
import { getFirebaseApp } from './firebase-app';
import { Hospital } from './classes/hospital';

// Hospitals live in Firestore now (managed by admins via the admin app's
// Hospitals page — see createHospital/deleteHospital in functions/src) —
// this replaces what used to be a hardcoded array. Read-only here: writes
// only ever happen through those Cloud Functions, since creating a hospital
// requires geocoding its address server-side.
@Injectable({ providedIn: 'root' })
export class HospitalService {
  private readonly firestore = getFirestore(getFirebaseApp());

  readonly hospitals = signal<Hospital[]>([]);
  readonly hospitalNames = computed(() => this.hospitals().map((hospital) => hospital.name));

  constructor() {
    const hospitalsQuery = query(collection(this.firestore, 'hospitals'), orderBy('name'));
    onSnapshot(hospitalsQuery, (snapshot) => {
      this.hospitals.set(
        snapshot.docs.map((docSnapshot) => ({ id: docSnapshot.id, ...(docSnapshot.data() as Omit<Hospital, 'id'>) })),
      );
    });
  }

  findHospital(name: string | undefined): Hospital | undefined {
    return this.hospitals().find((hospital) => hospital.name === name);
  }
}
