export interface CheckAccountStatusRequest {
  email: string;
  // Wire-value role strings (UserRole.wireValue on the Flutter side) the
  // calling app accepts — e.g. ['ems'], ['physician', 'nurse'],
  // ['admin', 'super-admin']. Lets checkAccountStatus catch "right
  // account, wrong app" immediately after the caller identifies
  // themselves by email, rather than only after they've set a password
  // and enrolled MFA — AppRouteGuard's own role tier only runs after both
  // of those succeed, which used to mean a real UX dead end this closes
  // further upstream instead. Empty/omitted skips the check entirely
  // (roleAllowed: true) rather than locking every caller out — defensive
  // against a stale client build that doesn't send it yet.
  allowedRoles?: string[];
}
