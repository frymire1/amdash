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
