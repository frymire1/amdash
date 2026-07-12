import { HOSPITAL_NAMES } from '@amdash/auth';

export interface PatientVitals {
  heartRate: number | string;
  bloodPressure: string;
  oxygen: number | string;
  temperature: number | string;
}

export interface PatientLocation {
  latitude: number;
  longitude: number;
  address: string;
}

export interface Patient {
  name: string;
  gender: string;
  age: number | string;
  healthcareNumber: string;
  vitals: PatientVitals;
  location: PatientLocation;
  notes?: string;
  destination?: string;
}

// Kept as the same hospitals the physician app's work-location picker uses
// (see @amdash/auth's HOSPITALS), so a destination here and a physician's
// work location always refer to the same physical place.
export const DESTINATION_HOSPITALS: readonly string[] = HOSPITAL_NAMES;
