import { UserRole } from './user-role';

// What getCallerProfile (functions/src/index.ts) reads off the caller's own
// users/{uid} doc — organizationId is absent for a super-admin, same as on
// the client-side UserProfile. uid/email are carried alongside for the
// audit log (functions/src/admin.ts) so callers of getCallerProfile don't
// need a second read just to attribute an action to who made it.
export interface CallerProfile {
  uid: string;
  email: string;
  role: UserRole[];
  organizationId?: string;
}
