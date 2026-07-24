export interface PatientVitals {
  heartRate: number | string;
  bloodPressure: string;
  oxygen: number | string;
  temperature: number | string;
  respiratoryRate?: number;
  // Glasgow Coma Scale total (3-15).
  gcs?: number;
}
