// Mirrors the shape of a patient's own `vitals` field (see patients.ts's
// vitalsEqual/appendVitalsHistory) plus who recorded it — `recordedAt` is
// added separately at write time via FieldValue.serverTimestamp(), not
// part of this interface. One document per actual change to vitals; see
// onPatientCreated/onPatientUpdated for the only two writers — never
// written by a client directly.
export interface VitalsHistoryEntry {
  heartRate: number | string;
  bloodPressure: string;
  oxygen: number | string;
  temperature: number | string;
  respiratoryRate?: number;
  gcs?: number;
  recordedBy?: string;
}
