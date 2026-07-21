import { PatientLocation } from './patient-location';
import { PatientVitals } from './patient-vitals';

// Shared by ems (which uploads/edits patients) and physician (which views
// them) — `id` is optional since ems constructs a Patient before it has a
// Firestore-assigned id (see ems's UploadedPatient, which pairs one with an
// id once it's known).
export interface Patient {
  id?: string;
  name: string;
  gender: string;
  age: number | string;
  healthcareNumber: string;
  vitals: PatientVitals;
  location: PatientLocation;
  notes?: string;
  destination?: string;
}
