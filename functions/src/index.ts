// Cloud Functions are organized by which app calls them: shared.ts (used by
// every app's login flow, plus the common getCallerProfile/findUserByEmail
// helpers), admin.ts (the admin app's org/user/hospital management), and
// ems.ts (the EMS live-location publish pipeline). There's no physician.ts
// yet — the physician app is currently read-only against Firestore and
// calls no Cloud Function of its own.
export * from './shared';
export * from './admin';
export * from './ems';
