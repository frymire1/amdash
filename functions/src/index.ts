// Cloud Functions are organized by domain, not by which app calls them:
// auth.ts (sign-in/account callables, plus the common
// getCallerProfile/findUserByEmail helpers every other domain file reads
// off of), patient-data.ts (patient CRUD/triggers, and the
// location/vitalsHistory Firestore ref builders ems.ts/physician.ts also
// need), admin.ts (the admin app's org/user/hospital management), ems.ts
// (the EMS live-location publish pipeline), physician.ts (the new-patient
// push alert trigger). kms.ts/audit.ts/fhir.ts/email.ts are plain helper
// modules, not Cloud Function files themselves, so they're imported
// directly by whichever domain file needs them rather than re-exported
// here.
export * from './auth';
export * from './patient-data';
export * from './admin';
export * from './ems';
export * from './physician';
