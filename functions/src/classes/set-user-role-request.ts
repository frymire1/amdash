import { AssignableRole } from './assignable-role';

export interface SetUserRoleRequest {
  email: string;
  role: AssignableRole;
}
