import { Injectable } from '@angular/core';
import { initializeApp } from 'firebase/app';
import { addDoc, collection, doc, getFirestore, serverTimestamp, updateDoc } from 'firebase/firestore';
import { Patient } from '../models/patient.model';

// Your web app's Firebase configuration
// For Firebase JS SDK v7.20.0 and later, measurementId is optional
const firebaseConfig = {
  apiKey: 'AIzaSyDHOpM_Mi9NcMeZS8sD42olEMyN_MjVl5k',
  authDomain: 'amdash-dev.firebaseapp.com',
  projectId: 'amdash-dev',
  storageBucket: 'amdash-dev.firebasestorage.app',
  messagingSenderId: '577422583971',
  appId: '1:577422583971:web:488d6ba962843f924fb716',
  measurementId: 'G-QXETV3X3MD',
};

@Injectable({ providedIn: 'root' })
export class PatientUploadService {
  private readonly app = initializeApp(firebaseConfig);
  private readonly firestore = getFirestore(this.app);

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
}
