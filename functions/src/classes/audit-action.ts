// One entry per admin-authored mutation in functions/src/admin.ts, plus the
// patient-record events logged from functions/src/patients.ts (both EMS's
// direct-write create/update/complete, attributed via the Firestore
// triggers there, and the decrypt read path) — see logAudit (audit.ts).
// Kept as a closed union (not a bare `string`) so a typo in a call site is a
// compile error, not a silently-malformed log entry.
export type AuditAction =
  | 'user.create'
  | 'user.update'
  | 'user.delete'
  | 'user.disable'
  | 'user.enable'
  | 'user.resendInvite'
  | 'user.resetMfa'
  | 'user.roleAdd'
  | 'user.roleRemove'
  | 'hospital.create'
  | 'hospital.update'
  | 'hospital.delete'
  | 'organization.create'
  | 'organization.setRetention'
  | 'organization.setCountry'
  | 'organization.setCmekPreference'
  | 'organization.setAuditLogging'
  | 'patient.create'
  | 'patient.update'
  | 'patient.complete'
  | 'patient.delete'
  | 'patient.decrypt';
