// Cloud Functions are organized by which app calls them: shared.ts (used by
// every app's login flow, plus the common getCallerProfile/findUserByEmail
// helpers), admin.ts (the admin app's org/user/hospital management), ems.ts
// (the EMS live-location publish pipeline), and physician.ts (the
// new-patient push alert trigger).
export * from './shared';
export * from './admin';
export * from './ems';
export * from './physician';
