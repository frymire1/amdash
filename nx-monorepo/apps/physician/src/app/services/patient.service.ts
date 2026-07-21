import { Injectable, signal } from '@angular/core';
import { collection, getFirestore, onSnapshot, orderBy, query } from 'firebase/firestore';
import { getFirebaseApp } from '../firebase';
import { Patient } from '@amdash/patients';

@Injectable({ providedIn: 'root' })
export class PatientService {
  private readonly firestore = getFirestore(getFirebaseApp());

  readonly patients = signal<Patient[]>([]);

  constructor() {
    const patientsQuery = query(collection(this.firestore, 'patients'), orderBy('submittedAt', 'desc'));
    onSnapshot(patientsQuery, (snapshot) => {
      this.patients.set(
        snapshot.docs.map((docSnapshot) => ({ id: docSnapshot.id, ...(docSnapshot.data() as Patient) })),
      );
    });
  }
}
