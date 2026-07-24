import { Injectable } from '@angular/core';
import { addDoc, collection, deleteDoc, deleteField, doc, getFirestore, serverTimestamp, updateDoc } from 'firebase/firestore';
import { getFirebaseApp } from '../firebase';
import { Patient } from '@amdash/patients';

// Optional top-level Patient fields the upload form can leave unset — see
// updatePatient below for why these specifically need deleteField().
const OPTIONAL_PATIENT_FIELDS = ['location', 'ivSize', 'ivPlacement', 'treatment'] as const;

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

  // updateDoc only touches the fields present in the object passed to it —
  // an optional field the form omits (because the EMS user cleared it) is
  // otherwise silently left at its previous value rather than cleared, since
  // Firestore has no way to distinguish "leave this field alone" from
  // "unset this field" other than the explicit deleteField() sentinel.
  // (vitals.respiratoryRate/vitals.gcs don't need this: `vitals` itself is
  // always present as a plain nested object, and Firestore replaces a
  // nested map wholesale rather than merging it, so omitting them there
  // already clears them.)
  async updatePatient(id: string, patient: Patient): Promise<void> {
    const update: Record<string, unknown> = { ...patient, updatedAt: serverTimestamp() };
    for (const field of OPTIONAL_PATIENT_FIELDS) {
      if (!(field in patient)) {
        update[field] = deleteField();
      }
    }
    await updateDoc(doc(this.firestore, 'patients', id), update);
  }

  async deletePatient(id: string): Promise<void> {
    await deleteDoc(doc(this.firestore, 'patients', id));
  }
}
