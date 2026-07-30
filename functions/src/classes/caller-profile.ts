import { UserRole } from './user-role';

// What getCallerProfile (functions/src/index.ts) reads off the caller's own
// users/{uid} doc — organizationId is absent for a super-admin, same as on
// the client-side UserProfile.
export interface CallerProfile {
  role: UserRole[];
  organizationId?: string;
}
