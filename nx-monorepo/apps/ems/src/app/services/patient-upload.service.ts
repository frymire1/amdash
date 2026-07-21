import { Injectable } from '@angular/core';
import { addDoc, collection, deleteDoc, doc, getFirestore, serverTimestamp, updateDoc } from 'firebase/firestore';
import { getFirebaseApp } from '../firebase';
import { Patient } from '@amdash/patients';

@Injectable({ providedIn: 'root' })
export class PatientUploadService {
  private readonly firestore = getFirestore(getFirebaseApp());

  async uploadPatient(patient: Patient): Promise<string> {
    const docRef = await addDoc(collection(this.firestore, 'patients'), {
      ...patient,
      submittedAt: serverTimestamp(),
    });
    return docRef.id;
  }

  async updatePatient(id: string, patient: Patient): Promise<void> {
    await updateDoc(doc(this.firestore, 'patients', id), {
      ...patient,
      updatedAt: serverTimestamp(),
    });
  }

  async deletePatient(id: string): Promise<void> {
    await deleteDoc(doc(this.firestore, 'patients', id));
  }
}
