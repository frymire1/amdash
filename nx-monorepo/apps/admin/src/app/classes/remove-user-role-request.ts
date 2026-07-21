import { AssignableRole } from './assignable-role';

export interface RemoveUserRoleRequest {
  email: string;
  role: AssignableRole;
}
