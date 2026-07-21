export type UserRole = 'ems' | 'physician' | 'nurse' | 'admin';

export interface UserProfile {
  // Optional: a freshly signed-up account has a Firestore reference (just an
  // email) before it has completed the mandatory name onboarding step.
  firstName?: string;
  lastName?: string;
  // A user can hold more than one role at once (e.g. physician + admin).
  // Only ever set server-side (see setUserRole/removeUserRole in
  // functions/src/index.ts) — clients are blocked from touching this field.
  role?: UserRole[];
  // Hospital name (see @amdash/auth's HospitalService) a physician/nurse
  // works out of — mandatory for those roles (see workLocationGuard),
  // unused by ems/admin accounts.
  workLocation?: string;
}
