import { Timestamp } from 'firebase/firestore';

export type UserRole = 'ems' | 'physician' | 'nurse' | 'admin' | 'super-admin';

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
  // Every role except 'super-admin' belongs to exactly one organization —
  // deliberately absent (not null) on a super-admin's own doc, since org
  // membership is meaningless for that role. Only ever set server-side
  // (createUser/createOrganization in functions/src/index.ts), same as
  // `role` — clients are blocked from touching this field too.
  organizationId?: string;
  // Set (and refreshed) by PatientAlertService.enableAlerts when a
  // physician/nurse arms new-patient push alerts for 1-12 hours; missing or
  // in the past means alerts are off. A Timestamp rather than a plain
  // boolean so the server-side sendNewPatientAlerts trigger can query for
  // "currently armed" directly instead of needing a separate cleanup job to
  // flip a boolean back off once the window elapses.
  newPatientAlertsExpiresAt?: Timestamp;
  // One FCM registration token per browser/device that has ever enabled
  // alerts, appended via arrayUnion (never overwritten) so enabling on a
  // second device doesn't drop the first's token. Stale tokens are pruned
  // server-side by sendNewPatientAlerts when FCM reports one as dead.
  fcmTokens?: string[];
}
