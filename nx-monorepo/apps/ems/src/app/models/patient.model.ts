export interface PatientVitals {
  heartRate: number;
  bloodPressure: string;
  oxygen: number;
  temperature: number;
}

export interface PatientLocation {
  latitude: number;
  longitude: number;
  address: string;
}

export interface Patient {
  name: string;
  gender: string;
  age: number;
  healthcareNumber: string;
  vitals: PatientVitals;
  location: PatientLocation;
}
