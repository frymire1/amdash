import { Injectable, inject } from '@angular/core';
import { addDoc, collection, deleteDoc, deleteField, doc, getFirestore, serverTimestamp, updateDoc } from 'firebase/firestore';
import { getFirebaseApp } from '../firebase';
import { Patient } from '@amdash/patients';
import { UserProfileService } from '@amdash/auth';

// Optional top-level Patient fields the upload form can leave unset — see
// updatePatient below for why these specifically need deleteField().
const OPTIONAL_PATIENT_FIELDS = ['location', 'ivSize', 'ivPlacement', 'treatment'] as const;

@Injectable({ providedIn: 'root' })
export class PatientUploadService {
  private readonly firestore = getFirestore(getFirebaseApp());
  private readonly userProfileService = inject(UserProfileService);

  async uploadPatient(patient: Patient): Promise<string> {
    const docRef = await addDoc(collection(this.firestore, 'patients'), {
      ...patient,
      // Stamped from the signed-in user's own profile, never client-chosen —
      // firestore.rules requires this to match the caller's own org on
      // create. Every EMS account always has an organizationId by the time
      // it can reach this page (assigned at account-creation time).
      organizationId: this.userProfileService.profile()?.organizationId,
      submittedAt: serverTimestamp(),
      // Both apps' active-patient queries filter on this — see
      // patient-session.service.ts/patient.service.ts. completeTransport()
      // below is the only other place this ever changes.
      status: 'active',
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
  // already clears them.) organizationId is deliberately never included
  // here — firestore.rules blocks changing it after creation.
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

  // Marks a transport done — this is what the "Complete Transport" button
  // on the summary card does, alongside stopping live tracking (see
  // patient-summary-card.component.ts). Both active-patient queries filter
  // this out immediately; the scheduled cleanupCompletedPatients function
  // (functions/src/admin.ts) deletes the doc entirely 48h later, unless the
  // org has turned on "retain all data" (admin app's Organization Settings).
  async completeTransport(id: string): Promise<void> {
    await updateDoc(doc(this.firestore, 'patients', id), {
      status: 'completed',
      completedAt: serverTimestamp(),
    });
  }
}
