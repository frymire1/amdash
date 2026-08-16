// Cloud Functions are organized by which app calls them: shared.ts (used by
// every app's login flow, plus the common getCallerProfile/findUserByEmail
// helpers), admin.ts (the admin app's org/user/hospital management), ems.ts
// (the EMS live-location publish pipeline), physician.ts (the new-patient
// push alert trigger), and patients.ts (Cloud KMS encrypt/decrypt callables
// shared by the EMS and physician apps — kms.ts itself is a plain helper
// module, not a Cloud Function file, so it's imported directly rather than
// re-exported here).
export * from './shared';
export * from './admin';
export * from './ems';
export * from './physician';
export * from './patients';
