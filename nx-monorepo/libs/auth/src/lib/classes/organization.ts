export interface Organization {
  id: string;
  name: string;
  // Missing/false = the default 48h cleanup applies to this org's completed
  // patients (see cleanupCompletedPatients, functions/src/admin.ts). Only
  // ever written by the setOrganizationRetention Cloud Function.
  retainAllData?: boolean;
}
