export interface EmsLocationEvent {
  patientId: string;
  organizationId: string;
  active: boolean;
  latitude?: number;
  longitude?: number;
}
