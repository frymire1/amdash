import { Injectable, signal } from '@angular/core';
import { collection, getFirestore, onSnapshot, query, where } from 'firebase/firestore';
import { getFirebaseApp } from '../firebase';

@Injectable({ providedIn: 'root' })
export class EmsLocationService {
  private readonly firestore = getFirestore(getFirebaseApp());

  readonly trackedPatientIds = signal<ReadonlySet<string>>(new Set());

  constructor() {
    const activeLocationsQuery = query(collection(this.firestore, 'emsLocations'), where('active', '==', true));

    onSnapshot(activeLocationsQuery, (snapshot) => {
      this.trackedPatientIds.set(new Set(snapshot.docs.map((docSnapshot) => docSnapshot.id)));
    });
  }

  isTracked(patientId: string | undefined): boolean {
    return !!patientId && this.trackedPatientIds().has(patientId);
  }
}
