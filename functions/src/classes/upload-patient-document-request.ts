// Mirrors the shape patient_upload_service.dart's _sharedFields already
// builds (the 'Unknown'-defaulting/optional-field-omission rules that
// apply identically to create and update) — this is that same shape plus
// plaintext name/healthcareNumber (encrypted server-side here, unlike
// updatePatient's direct write, which still calls encryptPatientFields
// itself first) and an optional initial GPS fix.
export interface UploadPatientDocumentRequest {
  name: string;
  gender: string;
  age: number | string;
  healthcareNumber: string;
  destination: string;
  vitals: {
    heartRate: number | string;
    bloodPressure: string;
    oxygen: number | string;
    temperature: number | string;
    respiratoryRate?: number;
    gcs?: number;
  };
  ivSize?: string;
  ivPlacement?: string;
  treatment?: string;
  notes: string;
  // Both present or both absent — the EMS device's GPS fix at the moment
  // of upload, if "live-track this patient" is on and a fix was obtained.
  // Seeded straight into patients/{id}/location/current, never onto the
  // patient doc itself.
  latitude?: number;
  longitude?: number;
}
