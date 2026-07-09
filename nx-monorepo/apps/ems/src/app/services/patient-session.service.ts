import { Injectable, signal } from '@angular/core';
import { Patient } from '../models/patient.model';

export interface UploadedPatient {
  id: string;
  patient: Patient;
}

@Injectable({ providedIn: 'root' })
export class PatientSessionService {
  readonly uploadedPatients = signal<UploadedPatient[]>([]);

  upsertUploadedPatient(id: string, patient: Patient) {
    this.uploadedPatients.update((patients) => {
      const index = patients.findIndex((uploaded) => uploaded.id === id);
      if (index === -1) {
        return [...patients, { id, patient }];
      }
      const next = [...patients];
      next[index] = { id, patient };
      return next;
    });
  }

  findUploadedPatient(id: string): UploadedPatient | undefined {
    return this.uploadedPatients().find((uploaded) => uploaded.id === id);
  }
}
