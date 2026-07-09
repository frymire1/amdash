import { Injectable, signal } from '@angular/core';
import { collection, getFirestore, onSnapshot, orderBy, query } from 'firebase/firestore';
import { getFirebaseApp } from '../firebase';
import { Patient } from '../models/patient.model';

export interface UploadedPatient {
  id: string;
  patient: Patient;
}

@Injectable({ providedIn: 'root' })
export class PatientSessionService {
  private readonly firestore = getFirestore(getFirebaseApp());

  readonly uploadedPatients = signal<UploadedPatient[]>([]);

  constructor() {
    const patientsQuery = query(collection(this.firestore, 'patients'), orderBy('submittedAt', 'desc'));
    onSnapshot(patientsQuery, (snapshot) => {
      this.uploadedPatients.set(
        snapshot.docs.map((docSnapshot) => ({
          id: docSnapshot.id,
          patient: docSnapshot.data() as Patient,
        })),
      );
    });
  }

  findUploadedPatient(id: string): UploadedPatient | undefined {
    return this.uploadedPatients().find((uploaded) => uploaded.id === id);
  }
}
