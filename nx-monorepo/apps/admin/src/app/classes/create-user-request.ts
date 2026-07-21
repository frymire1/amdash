import { AssignableRole } from './assignable-role';

export interface CreateUserRequest {
  email: string;
  firstName: string;
  lastName: string;
  role: AssignableRole;
}
