// One entry per admin-authored mutation in functions/src/admin.ts — see
// logAudit. Kept as a closed union (not a bare `string`) so a typo in a
// call site is a compile error, not a silently-malformed log entry.
export type AuditAction =
  | 'user.create'
  | 'user.update'
  | 'user.delete'
  | 'user.disable'
  | 'user.enable'
  | 'user.resendInvite'
  | 'user.roleAdd'
  | 'user.roleRemove'
  | 'hospital.create'
  | 'hospital.delete'
  | 'organization.create'
  | 'organization.setRetention';
