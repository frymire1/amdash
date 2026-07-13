import { Injectable, signal } from '@angular/core';
import { getFunctions, httpsCallable } from 'firebase/functions';
import { getFirebaseApp } from '@amdash/auth';

const FUNCTIONS_REGION = 'northamerica-northeast2';

export type AssignableRole = 'ems' | 'physician' | 'nurse';

export interface ManagedUser {
  uid: string;
  email: string;
  firstName: string;
  lastName: string;
  role: AssignableRole[];
}

interface SetUserRoleRequest {
  email: string;
  role: AssignableRole;
}

interface RemoveUserRoleRequest {
  email: string;
  role: AssignableRole;
}

interface SetUserRoleResponse {
  uid: string;
  email: string;
  role: string;
}

@Injectable({ providedIn: 'root' })
export class AdminService {
  private readonly functions = getFunctions(getFirebaseApp(), FUNCTIONS_REGION);
  private readonly setUserRoleFn = httpsCallable<SetUserRoleRequest, SetUserRoleResponse>(
    this.functions,
    'setUserRole',
  );
  private readonly removeUserRoleFn = httpsCallable<RemoveUserRoleRequest, SetUserRoleResponse>(
    this.functions,
    'removeUserRole',
  );
  private readonly listUsersWithRolesFn = httpsCallable<void, ManagedUser[]>(
    this.functions,
    'listUsersWithRoles',
  );

  readonly users = signal<ManagedUser[]>([]);
  readonly loadingUsers = signal(false);

  // Adds a role — a user can hold more than one at once. See removeUserRole
  // for the inverse.
  async setUserRole(email: string, role: AssignableRole): Promise<SetUserRoleResponse> {
    const result = await this.setUserRoleFn({ email, role });
    return result.data;
  }

  async removeUserRole(email: string, role: AssignableRole): Promise<SetUserRoleResponse> {
    const result = await this.removeUserRoleFn({ email, role });
    return result.data;
  }

  async refreshUsers(): Promise<void> {
    this.loadingUsers.set(true);
    try {
      const result = await this.listUsersWithRolesFn();
      this.users.set(result.data);
    } finally {
      this.loadingUsers.set(false);
    }
  }
}
