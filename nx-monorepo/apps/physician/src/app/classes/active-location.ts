export interface ActiveLocation {
  patientId: string;
  updatedAtMs: number;
  latitude?: number;
  longitude?: number;
  previousLatitude?: number;
  previousLongitude?: number;
  previousUpdatedAtMs?: number;
}
