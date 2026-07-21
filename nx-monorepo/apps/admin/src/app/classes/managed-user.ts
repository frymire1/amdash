import { AssignableRole } from './assignable-role';

export interface ManagedUser {
  uid: string;
  email: string;
  firstName: string;
  lastName: string;
  role: AssignableRole[];
}
