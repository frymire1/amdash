import { Injectable, signal } from '@angular/core';
import { getFunctions, httpsCallable } from 'firebase/functions';
import { getFirebaseApp, Hospital } from '@amdash/auth';

const FUNCTIONS_REGION = 'northamerica-northeast2';

export type AssignableRole = 'ems' | 'physician' | 'nurse';

export interface ManagedUser {
  uid: string;
  email: string;
  firstName: string;
  lastName: string;
  role: AssignableRole[];
}

interface CreateUserRequest {
  email: string;
  firstName: string;
  lastName: string;
  role: AssignableRole;
}

interface CreateUserResponse {
  uid: string;
  email: string;
  firstName: string;
  lastName: string;
  role: string;
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

interface CreateHospitalRequest {
  name: string;
  address: string;
}

interface DeleteHospitalRequest {
  hospitalId: string;
}

@Injectable({ providedIn: 'root' })
export class AdminService {
  private readonly functions = getFunctions(getFirebaseApp(), FUNCTIONS_REGION);
  private readonly createUserFn = httpsCallable<CreateUserRequest, CreateUserResponse>(
    this.functions,
    'createUser',
  );
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
  private readonly createHospitalFn = httpsCallable<CreateHospitalRequest, Hospital>(
    this.functions,
    'createHospital',
  );
  private readonly deleteHospitalFn = httpsCallable<DeleteHospitalRequest, { hospitalId: string }>(
    this.functions,
    'deleteHospital',
  );

  readonly users = signal<ManagedUser[]>([]);
  readonly loadingUsers = signal(false);

  // Creates a brand-new, passwordless account — the new user sets their own
  // password via the login page's "Forgot password?" link, not by signing
  // up (that would fail: the account already exists).
  async createUser(
    email: string,
    firstName: string,
    lastName: string,
    role: AssignableRole,
  ): Promise<CreateUserResponse> {
    const result = await this.createUserFn({ email, firstName, lastName, role });
    return result.data;
  }

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

  // Geocodes the address server-side and writes the hospitals/ doc — see
  // createHospital in functions/src/index.ts. No refreshHospitals() needed
  // afterward: HospitalService (@amdash/auth) already has a live Firestore
  // listener on the same collection, so the new hospital appears on its own.
  async createHospital(name: string, address: string): Promise<Hospital> {
    const result = await this.createHospitalFn({ name, address });
    return result.data;
  }

  async deleteHospital(hospitalId: string): Promise<void> {
    await this.deleteHospitalFn({ hospitalId });
  }
}
