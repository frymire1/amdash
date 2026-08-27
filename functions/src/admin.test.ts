import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fakeCallableRequest } from './test-utils';

// vi.hoisted() is required (not plain top-level consts) — see
// audit.test.ts's comment for why.
const {
  FakeTimestamp,
  mockUserGet,
  mockUserSet,
  mockUserUpdate,
  mockUserDelete,
  mockUserWhereGet,
  mockHospitalGet,
  mockHospitalUpdate,
  mockHospitalDelete,
  mockHospitalAdd,
  mockOrgGet,
  mockOrgUpdate,
  mockOrgWhereGet,
  mockOrgAdd,
  mockOrgsGet,
  mockPatientsWhereGet,
  mockAuditLogGet,
  mockBulkWriterDelete,
  mockBulkWriterClose,
  mockCollection,
  mockCreateAuthUser,
  mockUpdateAuthUser,
  mockDeleteAuthUser,
  mockGetAuthUser,
  mockGetAuthUsers,
  mockGetCallerProfile,
  mockFindUserByEmail,
  mockGetOrCreateOrgKey,
  mockSendWelcomeEmail,
  mockLogAudit,
  mockLoggerError,
} = vi.hoisted(() => {
  class FakeTimestamp {
    private readonly ms: number;
    private constructor(ms: number) {
      this.ms = ms;
    }
    static fromMillis(ms: number) {
      return new FakeTimestamp(ms);
    }
    toMillis() {
      return this.ms;
    }
  }

  const mockUserGet = vi.fn();
  const mockUserWhereGet = vi.fn();
  const usersWhereChain = { where: vi.fn(() => ({ where: vi.fn(() => ({ get: mockUserWhereGet })), get: mockUserWhereGet })) };

  const mockHospitalGet = vi.fn();
  const mockOrgGet = vi.fn();
  const mockOrgWhereGet = vi.fn();
  const mockOrgsGet = vi.fn();
  const mockPatientsWhereGet = vi.fn();
  const mockAuditLogGet = vi.fn();

  const mockCollection = vi.fn((name: string) => {
    if (name === 'users') {
      return {
        doc: (uid: string) => ({
          get: mockUserGet,
          set: mockUserSet,
          update: mockUserUpdate,
          delete: mockUserDelete,
          id: uid,
        }),
        where: usersWhereChain.where,
      };
    }
    if (name === 'hospitals') {
      return {
        doc: (id: string) => ({ get: mockHospitalGet, update: mockHospitalUpdate, delete: mockHospitalDelete, id }),
        add: mockHospitalAdd,
      };
    }
    if (name === 'organizations') {
      return {
        doc: (id: string) => ({ get: mockOrgGet, update: mockOrgUpdate, id }),
        where: vi.fn(() => ({ get: mockOrgWhereGet })),
        add: mockOrgAdd,
        get: mockOrgsGet,
      };
    }
    if (name === 'patients') {
      return { where: vi.fn(() => ({ where: vi.fn(() => ({ get: mockPatientsWhereGet })) })) };
    }
    if (name === 'auditLog') {
      return {
        where: vi.fn(() => ({
          orderBy: vi.fn(() => ({
            where: vi.fn(() => ({ limit: vi.fn(() => ({ get: mockAuditLogGet })) })),
            limit: vi.fn(() => ({ get: mockAuditLogGet })),
          })),
        })),
      };
    }
    throw new Error(`Unexpected collection in test: ${name}`);
  });

  const mockUserSet = vi.fn();
  const mockUserUpdate = vi.fn();
  const mockUserDelete = vi.fn();
  const mockHospitalUpdate = vi.fn();
  const mockHospitalDelete = vi.fn();
  const mockHospitalAdd = vi.fn();
  const mockOrgUpdate = vi.fn();
  const mockOrgAdd = vi.fn();
  const mockBulkWriterDelete = vi.fn();
  const mockBulkWriterClose = vi.fn();

  return {
    FakeTimestamp,
    mockUserGet,
    mockUserSet,
    mockUserUpdate,
    mockUserDelete,
    mockUserWhereGet,
    mockHospitalGet,
    mockHospitalUpdate,
    mockHospitalDelete,
    mockHospitalAdd,
    mockOrgGet,
    mockOrgUpdate,
    mockOrgWhereGet,
    mockOrgAdd,
    mockOrgsGet,
    mockPatientsWhereGet,
    mockAuditLogGet,
    mockBulkWriterDelete,
    mockBulkWriterClose,
    mockCollection,
    mockCreateAuthUser: vi.fn(),
    mockUpdateAuthUser: vi.fn(),
    mockDeleteAuthUser: vi.fn(),
    mockGetAuthUser: vi.fn(),
    mockGetAuthUsers: vi.fn(),
    mockGetCallerProfile: vi.fn(),
    mockFindUserByEmail: vi.fn(),
    mockGetOrCreateOrgKey: vi.fn(),
    mockSendWelcomeEmail: vi.fn(),
    mockLogAudit: vi.fn(),
    mockLoggerError: vi.fn(),
  };
});

vi.mock('firebase-admin/firestore', () => ({
  getFirestore: () => ({
    collection: mockCollection,
    bulkWriter: () => ({ delete: mockBulkWriterDelete, close: mockBulkWriterClose }),
  }),
  FieldValue: {
    serverTimestamp: () => 'SERVER_TIMESTAMP',
    arrayUnion: (v: unknown) => ({ __arrayUnion: v }),
    arrayRemove: (v: unknown) => ({ __arrayRemove: v }),
  },
  Timestamp: FakeTimestamp,
}));

vi.mock('firebase-admin/auth', () => ({
  getAuth: () => ({
    createUser: mockCreateAuthUser,
    updateUser: mockUpdateAuthUser,
    deleteUser: mockDeleteAuthUser,
    getUser: mockGetAuthUser,
    getUsers: mockGetAuthUsers,
  }),
}));

vi.mock('firebase-functions/params', () => ({
  defineSecret: () => ({ value: () => 'fake-geocoding-api-key' }),
}));

vi.mock('firebase-functions/v2', () => ({
  logger: { error: mockLoggerError },
}));

vi.mock('./auth', () => ({
  REGION: 'northamerica-northeast2',
  getCallerProfile: mockGetCallerProfile,
  findUserByEmail: mockFindUserByEmail,
}));

vi.mock('./kms', () => ({
  getOrCreateOrgKey: mockGetOrCreateOrgKey,
}));

vi.mock('./email', () => ({
  RESEND_API_KEY: 'fake-secret-param',
  sendWelcomeEmail: mockSendWelcomeEmail,
}));

vi.mock('./audit', () => ({
  SYSTEM_ACTOR: { uid: 'system', email: 'Automated (retention policy)' },
  logAudit: mockLogAudit,
}));

import {
  cleanupCompletedPatients,
  createHospital,
  createOrganization,
  createUser,
  deleteHospital,
  deleteUser,
  listAuditLog,
  listUsersWithRoles,
  removeUserRole,
  resendInvite,
  resetUserMfa,
  setOrganizationAuditLogging,
  setOrganizationCmekPreference,
  setOrganizationCountry,
  setOrganizationFhirExportEnabled,
  setOrganizationRetention,
  setUserDisabled,
  setUserRole,
  updateHospital,
  updateUser,
} from './admin';

const ADMIN_PROFILE = { uid: 'admin-uid', email: 'admin@example.com', role: ['admin'], organizationId: 'org-1' };
const SUPER_ADMIN_PROFILE = { uid: 'sa-uid', email: 'sa@example.com', role: ['super-admin'], organizationId: undefined };

function mockGeocodeFetchResponse(body: unknown) {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ json: () => Promise.resolve(body) }));
}

const OK_GEOCODE = { status: 'OK', results: [{ geometry: { location: { lat: 43.65, lng: -79.38 } } }] };

beforeEach(() => {
  vi.resetAllMocks();
  vi.unstubAllGlobals();
  // No admin-doc-related test relies on assertNotLastAdmin actually
  // blocking by default — give it a target with no admin role so it's a
  // no-op unless a specific test overrides mockUserWhereGet itself.
  mockUserWhereGet.mockResolvedValue({ docs: [] });
});

describe('createUser', () => {
  it('throws permission-denied for a non-admin caller', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...ADMIN_PROFILE, role: ['ems'] });
    await expect(
      createUser.run(fakeCallableRequest({ email: 'a@example.com', firstName: 'J', lastName: 'S', role: 'ems' }, 'uid-1')),
    ).rejects.toThrow('Only admins can create users.');
  });

  it('throws failed-precondition for an admin-role caller with no organizationId (shouldn\'t happen, but requireAdmin guards it explicitly)', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...ADMIN_PROFILE, organizationId: undefined });
    await expect(
      createUser.run(fakeCallableRequest({ email: 'a@example.com', firstName: 'J', lastName: 'S', role: 'ems' }, 'uid-1')),
    ).rejects.toThrow("isn't part of an organization");
  });

  it('throws invalid-argument for a bad role', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    await expect(
      createUser.run(
        fakeCallableRequest({ email: 'a@example.com', firstName: 'J', lastName: 'S', role: 'admin' as never }, 'uid-1'),
      ),
    ).rejects.toThrow('A valid email, first name, last name, and role');
  });

  it('throws invalid-argument when a required field is missing entirely', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    await expect(
      createUser.run(fakeCallableRequest({ email: '', firstName: 'J', lastName: 'S', role: 'ems' }, 'uid-1')),
    ).rejects.toThrow('A valid email, first name, last name, and role');
  });

  it('throws already-exists when the email is already registered', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockCreateAuthUser.mockRejectedValue({ code: 'auth/email-already-exists' });
    await expect(
      createUser.run(fakeCallableRequest({ email: 'a@example.com', firstName: 'J', lastName: 'S', role: 'ems' }, 'uid-1')),
    ).rejects.toThrow('An account with a@example.com already exists.');
  });

  it('throws internal for any other Auth account-creation failure', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockCreateAuthUser.mockRejectedValue({ code: 'auth/internal-error' });
    await expect(
      createUser.run(fakeCallableRequest({ email: 'a@example.com', firstName: 'J', lastName: 'S', role: 'ems' }, 'uid-1')),
    ).rejects.toThrow('Failed to create the account.');
  });

  it('creates the Auth user + Firestore profile, sends a welcome email, and logs audit on success', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockCreateAuthUser.mockResolvedValue({ uid: 'new-uid' });

    const result = await createUser.run(
      fakeCallableRequest({ email: 'a@example.com', firstName: 'Jordan', lastName: 'Smith', role: 'ems' }, 'uid-1'),
    );

    expect(mockUserSet).toHaveBeenCalledWith(
      expect.objectContaining({ email: 'a@example.com', role: ['ems'], organizationId: 'org-1' }),
    );
    expect(mockSendWelcomeEmail).toHaveBeenCalledWith({ email: 'a@example.com', firstName: 'Jordan', role: 'ems' });
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'user.create', target: 'new-uid' }));
    expect(result).toEqual({ uid: 'new-uid', email: 'a@example.com', firstName: 'Jordan', lastName: 'Smith', role: 'ems' });
  });
});

describe('setUserRole / removeUserRole', () => {
  beforeEach(() => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockFindUserByEmail.mockResolvedValue({ uid: 'target-uid', email: 'target@example.com' });
  });

  it('setUserRole throws invalid-argument for a bad role', async () => {
    await expect(
      setUserRole.run(fakeCallableRequest({ email: 'target@example.com', role: 'admin' as never }, 'uid-1')),
    ).rejects.toThrow('A valid email and role');
  });

  it('removeUserRole throws invalid-argument for a missing email', async () => {
    await expect(
      removeUserRole.run(fakeCallableRequest({ email: '', role: 'physician' }, 'uid-1')),
    ).rejects.toThrow('A valid email and role');
  });

  it('setUserRole throws permission-denied for a target in a different organization', async () => {
    mockUserGet.mockResolvedValue({ data: () => ({ organizationId: 'org-2' }) });
    await expect(
      setUserRole.run(fakeCallableRequest({ email: 'target@example.com', role: 'physician' }, 'uid-1')),
    ).rejects.toThrow('is not a member of your organization.');
  });

  it('setUserRole adds the role via arrayUnion and logs audit', async () => {
    mockUserGet.mockResolvedValue({ data: () => ({ organizationId: 'org-1' }) });
    const result = await setUserRole.run(fakeCallableRequest({ email: 'target@example.com', role: 'physician' }, 'uid-1'));

    expect(mockUserSet).toHaveBeenCalledWith({ role: { __arrayUnion: 'physician' } }, { merge: true });
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'user.roleAdd' }));
    expect(result).toEqual({ uid: 'target-uid', email: 'target@example.com', role: 'physician' });
  });

  it('removeUserRole removes the role via arrayRemove and logs audit', async () => {
    mockUserGet.mockResolvedValue({ data: () => ({ organizationId: 'org-1' }) });
    await removeUserRole.run(fakeCallableRequest({ email: 'target@example.com', role: 'physician' }, 'uid-1'));

    expect(mockUserUpdate).toHaveBeenCalledWith({ role: { __arrayRemove: 'physician' } });
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'user.roleRemove' }));
  });
});

describe('updateUser', () => {
  beforeEach(() => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
  });

  it('throws invalid-argument when no uid, or no field to update, is given', async () => {
    await expect(updateUser.run(fakeCallableRequest({ uid: '', firstName: 'New' }, 'uid-1'))).rejects.toThrow(
      'A uid and at least one of email, firstName, or lastName are required.',
    );
    await expect(updateUser.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'))).rejects.toThrow(
      'A uid and at least one of email, firstName, or lastName are required.',
    );
  });

  it('throws not-found when the target no longer exists', async () => {
    mockUserGet.mockResolvedValue({ exists: false });
    await expect(updateUser.run(fakeCallableRequest({ uid: 'target-uid', firstName: 'New' }, 'uid-1'))).rejects.toThrow(
      'That user no longer exists.',
    );
  });

  it('throws already-exists when the new email collides with another account', async () => {
    mockUserGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1' }) });
    mockUpdateAuthUser.mockRejectedValue({ code: 'auth/email-already-exists' });
    await expect(
      updateUser.run(fakeCallableRequest({ uid: 'target-uid', email: 'taken@example.com' }, 'uid-1')),
    ).rejects.toThrow('An account with taken@example.com already exists.');
  });

  it('throws internal for any other Auth update failure', async () => {
    mockUserGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1' }) });
    mockUpdateAuthUser.mockRejectedValue({ code: 'auth/internal-error' });
    await expect(
      updateUser.run(fakeCallableRequest({ uid: 'target-uid', email: 'new@example.com' }, 'uid-1')),
    ).rejects.toThrow('Failed to update the email address.');
  });

  it('updates only the fields actually provided, and logs exactly that diff', async () => {
    mockUserGet.mockResolvedValue({
      exists: true,
      data: () => ({ organizationId: 'org-1', email: 'old@example.com', firstName: 'Old', lastName: 'Name', role: ['ems'] }),
    });

    const result = await updateUser.run(fakeCallableRequest({ uid: 'target-uid', firstName: 'New' }, 'uid-1'));

    expect(mockUpdateAuthUser).not.toHaveBeenCalled(); // no email change
    expect(mockUserUpdate).toHaveBeenCalledWith({ firstName: 'New' });
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ details: { firstName: 'New' } }));
    expect(result).toEqual({ uid: 'target-uid', email: 'old@example.com', firstName: 'New', lastName: 'Name', role: ['ems'] });
  });

  it('updates email alone (no firstName/lastName in the request)', async () => {
    mockUserGet.mockResolvedValue({
      exists: true,
      data: () => ({ organizationId: 'org-1', email: 'old@example.com', firstName: 'Existing', lastName: 'Name', role: ['ems'] }),
    });
    mockUpdateAuthUser.mockResolvedValue(undefined);

    const result = await updateUser.run(fakeCallableRequest({ uid: 'target-uid', email: 'new@example.com' }, 'uid-1'));

    expect(mockUserUpdate).toHaveBeenCalledWith({ email: 'new@example.com' });
    expect(result).toEqual({ uid: 'target-uid', email: 'new@example.com', firstName: 'Existing', lastName: 'Name', role: ['ems'] });
  });

  it('updates email, firstName, and lastName all together when Auth accepts the new email', async () => {
    mockUserGet.mockResolvedValue({
      exists: true,
      data: () => ({ organizationId: 'org-1', email: 'old@example.com', firstName: 'Old', lastName: 'Name', role: ['ems'] }),
    });
    mockUpdateAuthUser.mockResolvedValue(undefined);

    const result = await updateUser.run(
      fakeCallableRequest({ uid: 'target-uid', email: 'new@example.com', firstName: 'New', lastName: 'Surname' }, 'uid-1'),
    );

    expect(mockUpdateAuthUser).toHaveBeenCalledWith('target-uid', { email: 'new@example.com' });
    expect(mockUserUpdate).toHaveBeenCalledWith({ email: 'new@example.com', firstName: 'New', lastName: 'Surname' });
    expect(result).toEqual({ uid: 'target-uid', email: 'new@example.com', firstName: 'New', lastName: 'Surname', role: ['ems'] });
  });

  it('falls back email/lastName/role to their zero-values when neither the update nor the existing doc has them', async () => {
    mockUserGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1' }) }); // no email/lastName/role at all

    const result = await updateUser.run(fakeCallableRequest({ uid: 'target-uid', firstName: 'New' }, 'uid-1'));

    expect(result).toEqual({ uid: 'target-uid', email: '', firstName: 'New', lastName: '', role: [] });
  });

  it('falls back firstName/lastName to "" too when updating email only on a doc with neither on record', async () => {
    mockUserGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1' }) }); // no firstName/lastName at all
    mockUpdateAuthUser.mockResolvedValue(undefined);

    const result = await updateUser.run(fakeCallableRequest({ uid: 'target-uid', email: 'new@example.com' }, 'uid-1'));

    expect(result).toEqual({ uid: 'target-uid', email: 'new@example.com', firstName: '', lastName: '', role: [] });
  });
});

describe('deleteUser', () => {
  beforeEach(() => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
  });

  it('throws invalid-argument when uid is missing', async () => {
    await expect(deleteUser.run(fakeCallableRequest({ uid: '' }, 'uid-1'))).rejects.toThrow('A uid is required.');
  });

  it('throws not-found when the target no longer exists', async () => {
    mockUserGet.mockResolvedValue({ exists: false });
    await expect(deleteUser.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'))).rejects.toThrow(
      'That user no longer exists.',
    );
  });

  it('throws failed-precondition when deleting would leave the org with zero admins', async () => {
    mockUserGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1', role: ['admin'] }) });
    mockUserWhereGet.mockResolvedValue({ docs: [{ id: 'target-uid' }] }); // only admin left is the target itself

    await expect(deleteUser.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'))).rejects.toThrow(
      "Can't delete the last admin in this organization.",
    );
    expect(mockDeleteAuthUser).not.toHaveBeenCalled();
  });

  it('deletes the Auth account + Firestore doc and logs audit when not the last admin', async () => {
    mockUserGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1', role: ['ems'], email: 'a@example.com' }) });

    const result = await deleteUser.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'));

    expect(mockDeleteAuthUser).toHaveBeenCalledWith('target-uid');
    expect(mockUserDelete).toHaveBeenCalledTimes(1);
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'user.delete' }));
    expect(result).toEqual({ uid: 'target-uid' });
  });

  it('allows deleting an admin who is not the org\'s only one', async () => {
    mockUserGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1', role: ['admin'], email: 'a@example.com' }) });
    // Two admins on record; the target is one of them, so one remains.
    mockUserWhereGet.mockResolvedValue({ docs: [{ id: 'target-uid' }, { id: 'other-admin-uid' }] });

    const result = await deleteUser.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'));

    expect(mockDeleteAuthUser).toHaveBeenCalledWith('target-uid');
    expect(result).toEqual({ uid: 'target-uid' });
  });

  it('treats a target doc that exists but has no data() as an empty object rather than crashing on it', async () => {
    // organizationId ends up undefined either way, so this still fails —
    // but via the ordinary "different organization" check
    // (requireSameOrg), not a TypeError from indexing into undefined.
    mockUserGet.mockResolvedValue({ exists: true, data: () => undefined });
    await expect(deleteUser.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'))).rejects.toThrow(
      'That user is not a member of your organization.',
    );
  });
});

describe('setUserDisabled', () => {
  beforeEach(() => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockUserGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1', role: ['ems'] }) });
  });

  it('throws invalid-argument when uid or the disabled boolean is missing', async () => {
    await expect(setUserDisabled.run(fakeCallableRequest({ uid: '', disabled: true }, 'uid-1'))).rejects.toThrow(
      'A uid and a disabled boolean are required.',
    );
    await expect(
      setUserDisabled.run(fakeCallableRequest({ uid: 'target-uid', disabled: undefined as never }, 'uid-1')),
    ).rejects.toThrow('A uid and a disabled boolean are required.');
  });

  it('throws not-found when the target no longer exists', async () => {
    mockUserGet.mockResolvedValue({ exists: false });
    await expect(setUserDisabled.run(fakeCallableRequest({ uid: 'target-uid', disabled: true }, 'uid-1'))).rejects.toThrow(
      'That user no longer exists.',
    );
  });

  it('checks assertNotLastAdmin only when disabling (not when re-enabling)', async () => {
    await setUserDisabled.run(fakeCallableRequest({ uid: 'target-uid', disabled: false }, 'uid-1'));
    expect(mockUserWhereGet).not.toHaveBeenCalled();
  });

  it('suspends the account and logs user.disable', async () => {
    const result = await setUserDisabled.run(fakeCallableRequest({ uid: 'target-uid', disabled: true }, 'uid-1'));
    expect(mockUpdateAuthUser).toHaveBeenCalledWith('target-uid', { disabled: true });
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'user.disable' }));
    expect(result).toEqual({ uid: 'target-uid', disabled: true });
  });

  it('reactivates the account and logs user.enable', async () => {
    await setUserDisabled.run(fakeCallableRequest({ uid: 'target-uid', disabled: false }, 'uid-1'));
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'user.enable' }));
  });
});

describe('resetUserMfa', () => {
  beforeEach(() => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
  });

  it('throws invalid-argument when uid is missing', async () => {
    await expect(resetUserMfa.run(fakeCallableRequest({ uid: '' }, 'uid-1'))).rejects.toThrow('A uid is required.');
  });

  it('throws not-found when the target no longer exists', async () => {
    mockUserGet.mockResolvedValue({ exists: false });
    await expect(resetUserMfa.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'))).rejects.toThrow(
      'That user no longer exists.',
    );
  });

  it('clears enrolledFactors and logs audit', async () => {
    mockUserGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1' }) });

    await resetUserMfa.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'));

    expect(mockUpdateAuthUser).toHaveBeenCalledWith('target-uid', { multiFactor: { enrolledFactors: [] } });
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'user.resetMfa' }));
  });
});

describe('resendInvite', () => {
  beforeEach(() => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
  });

  it('throws invalid-argument when uid is missing', async () => {
    await expect(resendInvite.run(fakeCallableRequest({ uid: '' }, 'uid-1'))).rejects.toThrow('A uid is required.');
  });

  it('throws not-found when the target no longer exists', async () => {
    mockUserGet.mockResolvedValue({ exists: false });
    await expect(resendInvite.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'))).rejects.toThrow(
      'That user no longer exists.',
    );
  });

  it('throws failed-precondition when the account already has a password', async () => {
    mockUserGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1', role: ['ems'] }) });
    mockGetAuthUser.mockResolvedValue({ providerData: [{ providerId: 'password' }] });
    await expect(resendInvite.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'))).rejects.toThrow(
      'This account already has a password set.',
    );
  });

  it('throws failed-precondition when the target has no assignable role to base the link on', async () => {
    mockUserGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1', role: ['admin'] }) });
    mockGetAuthUser.mockResolvedValue({ providerData: [] });
    await expect(resendInvite.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'))).rejects.toThrow(
      'no ems/physician/nurse role',
    );
  });

  it('also throws failed-precondition when role is missing/not an array at all', async () => {
    mockUserGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1' }) });
    mockGetAuthUser.mockResolvedValue({ providerData: [] });
    await expect(resendInvite.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'))).rejects.toThrow(
      'no ems/physician/nurse role',
    );
  });

  it('treats a target doc that exists but has no data() as an empty object rather than crashing on it', async () => {
    mockUserGet.mockResolvedValue({ exists: true, data: () => undefined });
    await expect(resendInvite.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'))).rejects.toThrow(
      'That user is not a member of your organization.',
    );
  });

  it('resends the welcome email and logs audit on success', async () => {
    mockUserGet.mockResolvedValue({
      exists: true,
      data: () => ({ organizationId: 'org-1', role: ['ems'], email: 'a@example.com', firstName: 'Jordan' }),
    });
    mockGetAuthUser.mockResolvedValue({ providerData: [] });

    await resendInvite.run(fakeCallableRequest({ uid: 'target-uid' }, 'uid-1'));

    expect(mockSendWelcomeEmail).toHaveBeenCalledWith({ email: 'a@example.com', firstName: 'Jordan', role: 'ems' });
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'user.resendInvite' }));
  });
});

describe('listUsersWithRoles', () => {
  it('throws permission-denied for a non-admin caller', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...ADMIN_PROFILE, role: ['ems'] });
    await expect(listUsersWithRoles.run(fakeCallableRequest({}, 'uid-1'))).rejects.toThrow('Only admins can list users.');
  });

  it('skips the Auth batch lookup entirely for an org with no users', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockUserWhereGet.mockResolvedValue({ docs: [] });

    const result = await listUsersWithRoles.run(fakeCallableRequest({}, 'uid-1'));

    expect(mockGetAuthUsers).not.toHaveBeenCalled();
    expect(result).toEqual([]);
  });

  it('merges Firestore profile fields with batched Auth account status', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockUserWhereGet.mockResolvedValue({
      docs: [{ id: 'u1', data: () => ({ email: 'a@example.com', firstName: 'J', lastName: 'S', role: ['ems'] }) }],
    });
    mockGetAuthUsers.mockResolvedValue({
      users: [{ uid: 'u1', disabled: true, providerData: [{ providerId: 'password' }], multiFactor: { enrolledFactors: [{}] } }],
    });

    const result = await listUsersWithRoles.run(fakeCallableRequest({}, 'uid-1'));

    expect(result).toEqual([
      { uid: 'u1', email: 'a@example.com', firstName: 'J', lastName: 'S', role: ['ems'], disabled: true, hasPassword: true, mfaEnrolled: true },
    ]);
  });

  it('falls back every field to its zero-value for a profile doc with nothing set and no matching Auth record', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockUserWhereGet.mockResolvedValue({ docs: [{ id: 'u2', data: () => ({}) }] });
    // Auth batch returns *some* user, but not u2 — authByUid.get('u2') is
    // undefined, exercising every `authInfo?.x ?? default` fallback.
    mockGetAuthUsers.mockResolvedValue({
      users: [{ uid: 'someone-else', disabled: false, providerData: [], multiFactor: undefined }],
    });

    const result = await listUsersWithRoles.run(fakeCallableRequest({}, 'uid-1'));

    expect(result).toEqual([
      { uid: 'u2', email: '', firstName: '', lastName: '', role: [], disabled: false, hasPassword: false, mfaEnrolled: false },
    ]);
  });
});

describe('createHospital', () => {
  beforeEach(() => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
  });

  it('throws invalid-argument when name or address is missing', async () => {
    await expect(createHospital.run(fakeCallableRequest({ name: '', address: '1 Main St' }, 'uid-1'))).rejects.toThrow(
      'A hospital name and address are required.',
    );
  });

  it('throws not-found when geocoding fails to find the address', async () => {
    mockGeocodeFetchResponse({ status: 'ZERO_RESULTS', results: [] });
    await expect(
      createHospital.run(fakeCallableRequest({ name: 'General', address: 'nowhere' }, 'uid-1')),
    ).rejects.toThrow('Could not find coordinates');
  });

  it('geocodes the address, writes the hospital doc, and logs audit', async () => {
    mockGeocodeFetchResponse(OK_GEOCODE);
    mockHospitalAdd.mockResolvedValue({ id: 'hosp-1' });

    const result = await createHospital.run(fakeCallableRequest({ name: 'General', address: '1 Main St' }, 'uid-1'));

    expect(mockHospitalAdd).toHaveBeenCalledWith(
      expect.objectContaining({ name: 'General', address: '1 Main St', latitude: 43.65, longitude: -79.38, organizationId: 'org-1' }),
    );
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'hospital.create', target: 'hosp-1' }));
    expect(result).toEqual({ id: 'hosp-1', name: 'General', address: '1 Main St', latitude: 43.65, longitude: -79.38 });
  });
});

describe('updateHospital', () => {
  beforeEach(() => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockHospitalGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1', name: 'Old', address: 'Old Addr' }) });
  });

  it('throws invalid-argument when hospitalId is missing, or neither name nor address is given', async () => {
    await expect(
      updateHospital.run(fakeCallableRequest({ hospitalId: '', name: 'New' }, 'uid-1')),
    ).rejects.toThrow('A hospitalId and at least one of name or address are required.');
    await expect(
      updateHospital.run(fakeCallableRequest({ hospitalId: 'hosp-1' }, 'uid-1')),
    ).rejects.toThrow('A hospitalId and at least one of name or address are required.');
  });

  it('throws not-found when the hospital no longer exists', async () => {
    mockHospitalGet.mockResolvedValue({ exists: false });
    await expect(
      updateHospital.run(fakeCallableRequest({ hospitalId: 'hosp-1', name: 'New' }, 'uid-1')),
    ).rejects.toThrow('That hospital no longer exists.');
  });

  it('re-geocodes when the address changes', async () => {
    mockGeocodeFetchResponse(OK_GEOCODE);
    await updateHospital.run(fakeCallableRequest({ hospitalId: 'hosp-1', address: 'New Addr' }, 'uid-1'));
    expect(mockHospitalUpdate).toHaveBeenCalledWith({ address: 'New Addr', latitude: 43.65, longitude: -79.38 });
  });

  it('does not re-geocode when only the name changes', async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);
    await updateHospital.run(fakeCallableRequest({ hospitalId: 'hosp-1', name: 'New Name' }, 'uid-1'));
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(mockHospitalUpdate).toHaveBeenCalledWith({ name: 'New Name' });
  });

  it('echoes the existing lat/lng in the response when only the name changes (no fresh geocode to use instead)', async () => {
    mockHospitalGet.mockResolvedValue({
      exists: true,
      data: () => ({ organizationId: 'org-1', name: 'Old', address: 'Old Addr', latitude: 1.1, longitude: 2.2 }),
    });
    const result = await updateHospital.run(fakeCallableRequest({ hospitalId: 'hosp-1', name: 'New Name' }, 'uid-1'));
    expect(result).toEqual({ id: 'hosp-1', name: 'New Name', address: 'Old Addr', latitude: 1.1, longitude: 2.2 });
  });

  it('falls back name to "" when updating address only on a hospital that never had one recorded', async () => {
    mockHospitalGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1', address: 'Old Addr' }) }); // no name at all
    mockGeocodeFetchResponse(OK_GEOCODE);
    const result = await updateHospital.run(fakeCallableRequest({ hospitalId: 'hosp-1', address: 'New Addr' }, 'uid-1'));
    expect(result).toEqual({ id: 'hosp-1', name: '', address: 'New Addr', latitude: 43.65, longitude: -79.38 });
  });

  it('falls back address to "" when updating name only on a hospital that never had one recorded', async () => {
    mockHospitalGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1', name: 'Old' }) }); // no address at all
    const result = await updateHospital.run(fakeCallableRequest({ hospitalId: 'hosp-1', name: 'New Name' }, 'uid-1'));
    expect(result).toEqual({ id: 'hosp-1', name: 'New Name', address: '', latitude: 0, longitude: 0 });
  });

  it('treats a hospital doc that exists but has no data() as an empty object rather than crashing on it', async () => {
    mockHospitalGet.mockResolvedValue({ exists: true, data: () => undefined });
    await expect(updateHospital.run(fakeCallableRequest({ hospitalId: 'hosp-1', name: 'New' }, 'uid-1'))).rejects.toThrow(
      'That hospital belongs to a different organization.',
    );
  });
});

describe('deleteHospital', () => {
  it('throws invalid-argument when hospitalId is missing', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    await expect(deleteHospital.run(fakeCallableRequest({ hospitalId: '' }, 'uid-1'))).rejects.toThrow(
      'A hospitalId is required.',
    );
  });

  it('throws permission-denied for a hospital in a different organization', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockHospitalGet.mockResolvedValue({ data: () => ({ organizationId: 'org-2' }) });
    await expect(deleteHospital.run(fakeCallableRequest({ hospitalId: 'hosp-1' }, 'uid-1'))).rejects.toThrow(
      'That hospital belongs to a different organization.',
    );
  });

  it('deletes and logs audit for a same-org hospital', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockHospitalGet.mockResolvedValue({ data: () => ({ organizationId: 'org-1', name: 'General' }) });
    const result = await deleteHospital.run(fakeCallableRequest({ hospitalId: 'hosp-1' }, 'uid-1'));
    expect(mockHospitalDelete).toHaveBeenCalledTimes(1);
    expect(result).toEqual({ hospitalId: 'hosp-1' });
  });

  it('treats a hospital doc with no data() as an empty object rather than crashing on it', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockHospitalGet.mockResolvedValue({ data: () => undefined });
    await expect(deleteHospital.run(fakeCallableRequest({ hospitalId: 'hosp-1' }, 'uid-1'))).rejects.toThrow(
      'That hospital belongs to a different organization.',
    );
  });
});

describe('createOrganization', () => {
  it('throws permission-denied for a non-super-admin caller', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    await expect(
      createOrganization.run(
        fakeCallableRequest({ organizationName: 'X', adminEmail: 'a@x.com', adminFirstName: 'J', adminLastName: 'S', country: 'CA' }, 'uid-1'),
      ),
    ).rejects.toThrow('Only the super-admin can create organizations.');
  });

  it('throws invalid-argument when a required field is missing or country is invalid', async () => {
    mockGetCallerProfile.mockResolvedValue(SUPER_ADMIN_PROFILE);
    await expect(
      createOrganization.run(
        fakeCallableRequest({ organizationName: '', adminEmail: 'a@x.com', adminFirstName: 'J', adminLastName: 'S', country: 'CA' }, 'sa-uid'),
      ),
    ).rejects.toThrow('An organization name, country, and the first admin');
    await expect(
      createOrganization.run(
        fakeCallableRequest(
          { organizationName: 'X', adminEmail: 'a@x.com', adminFirstName: 'J', adminLastName: 'S', country: 'ZZ' as never },
          'sa-uid',
        ),
      ),
    ).rejects.toThrow('An organization name, country, and the first admin');
  });

  it('throws already-exists when an organization with that name exists', async () => {
    mockGetCallerProfile.mockResolvedValue(SUPER_ADMIN_PROFILE);
    mockOrgWhereGet.mockResolvedValue({ empty: false });
    await expect(
      createOrganization.run(
        fakeCallableRequest({ organizationName: 'X', adminEmail: 'a@x.com', adminFirstName: 'J', adminLastName: 'S', country: 'CA' }, 'sa-uid'),
      ),
    ).rejects.toThrow('already exists');
  });

  it('throws already-exists when the admin email is already registered', async () => {
    mockGetCallerProfile.mockResolvedValue(SUPER_ADMIN_PROFILE);
    mockOrgWhereGet.mockResolvedValue({ empty: true });
    mockCreateAuthUser.mockRejectedValue({ code: 'auth/email-already-exists' });
    await expect(
      createOrganization.run(
        fakeCallableRequest(
          { organizationName: 'X', adminEmail: 'taken@x.com', adminFirstName: 'J', adminLastName: 'S', country: 'CA' },
          'sa-uid',
        ),
      ),
    ).rejects.toThrow('An account with taken@x.com already exists.');
  });

  it('throws internal for any other Auth account-creation failure', async () => {
    mockGetCallerProfile.mockResolvedValue(SUPER_ADMIN_PROFILE);
    mockOrgWhereGet.mockResolvedValue({ empty: true });
    mockCreateAuthUser.mockRejectedValue({ code: 'auth/internal-error' });
    await expect(
      createOrganization.run(
        fakeCallableRequest(
          { organizationName: 'X', adminEmail: 'a@x.com', adminFirstName: 'J', adminLastName: 'S', country: 'CA' },
          'sa-uid',
        ),
      ),
    ).rejects.toThrow('Failed to create the admin account.');
  });

  it('creates the org, its first admin, and logs audit', async () => {
    mockGetCallerProfile.mockResolvedValue(SUPER_ADMIN_PROFILE);
    mockOrgWhereGet.mockResolvedValue({ empty: true });
    mockCreateAuthUser.mockResolvedValue({ uid: 'new-admin-uid' });
    mockOrgAdd.mockResolvedValue({ id: 'new-org-id' });

    const result = await createOrganization.run(
      fakeCallableRequest(
        { organizationName: 'Northside EMS', adminEmail: 'a@x.com', adminFirstName: 'Jordan', adminLastName: 'Smith', country: 'CA' },
        'sa-uid',
      ),
    );

    expect(mockUserSet).toHaveBeenCalledWith(
      expect.objectContaining({ role: ['admin'], organizationId: 'new-org-id' }),
    );
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'organization.create', organizationId: 'new-org-id' }));
    expect(result).toEqual({
      organizationId: 'new-org-id',
      organizationName: 'Northside EMS',
      adminUid: 'new-admin-uid',
      adminEmail: 'a@x.com',
      country: 'CA',
    });
  });
});

describe('organization settings toggles', () => {
  beforeEach(() => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
  });

  it('setOrganizationRetention rejects a non-boolean retainAllData', async () => {
    await expect(
      setOrganizationRetention.run(fakeCallableRequest({ retainAllData: 'yes' as never }, 'uid-1')),
    ).rejects.toThrow('retainAllData must be a boolean.');
  });

  it('setOrganizationRetention updates and logs', async () => {
    const result = await setOrganizationRetention.run(fakeCallableRequest({ retainAllData: true }, 'uid-1'));
    expect(mockOrgUpdate).toHaveBeenCalledWith({ retainAllData: true });
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'organization.setRetention' }));
    expect(result).toEqual({ retainAllData: true });
  });

  it('setOrganizationCountry rejects an invalid country code', async () => {
    await expect(setOrganizationCountry.run(fakeCallableRequest({ country: 'ZZ' } as never, 'uid-1'))).rejects.toThrow(
      'country must be one of',
    );
  });

  it('setOrganizationCountry updates and logs for a valid code', async () => {
    const result = await setOrganizationCountry.run(fakeCallableRequest({ country: 'CA' }, 'uid-1'));
    expect(mockOrgUpdate).toHaveBeenCalledWith({ country: 'CA' });
    expect(result).toEqual({ country: 'CA' });
  });

  it('setOrganizationCmekPreference rejects a non-boolean cmekRequested', async () => {
    await expect(
      setOrganizationCmekPreference.run(fakeCallableRequest({ cmekRequested: 'yes' as never }, 'uid-1')),
    ).rejects.toThrow('cmekRequested must be a boolean.');
  });

  it('setOrganizationCmekPreference provisions a key when turning on', async () => {
    mockGetOrCreateOrgKey.mockResolvedValue('projects/p/.../org-1');
    await setOrganizationCmekPreference.run(fakeCallableRequest({ cmekRequested: true }, 'uid-1'));
    expect(mockOrgUpdate).toHaveBeenCalledWith({ cmekRequested: true, kmsKeyName: 'projects/p/.../org-1' });
  });

  it('setOrganizationCmekPreference throws internal when key provisioning fails', async () => {
    mockGetOrCreateOrgKey.mockRejectedValue(new Error('KMS unavailable'));
    await expect(setOrganizationCmekPreference.run(fakeCallableRequest({ cmekRequested: true }, 'uid-1'))).rejects.toThrow(
      "Couldn't set up the encryption key",
    );
  });

  it('setOrganizationCmekPreference does not touch KMS when turning off', async () => {
    await setOrganizationCmekPreference.run(fakeCallableRequest({ cmekRequested: false }, 'uid-1'));
    expect(mockGetOrCreateOrgKey).not.toHaveBeenCalled();
    expect(mockOrgUpdate).toHaveBeenCalledWith({ cmekRequested: false });
  });

  it('setOrganizationAuditLogging rejects a non-boolean auditLoggingEnabled', async () => {
    await expect(
      setOrganizationAuditLogging.run(fakeCallableRequest({ auditLoggingEnabled: 'no' as never }, 'uid-1')),
    ).rejects.toThrow('auditLoggingEnabled must be a boolean.');
  });

  it('setOrganizationAuditLogging updates and logs', async () => {
    const result = await setOrganizationAuditLogging.run(fakeCallableRequest({ auditLoggingEnabled: false }, 'uid-1'));
    expect(mockOrgUpdate).toHaveBeenCalledWith({ auditLoggingEnabled: false });
    expect(result).toEqual({ auditLoggingEnabled: false });
  });

  it('setOrganizationFhirExportEnabled rejects a non-boolean fhirExportEnabled', async () => {
    await expect(
      setOrganizationFhirExportEnabled.run(fakeCallableRequest({ fhirExportEnabled: 'yes' as never }, 'uid-1')),
    ).rejects.toThrow('fhirExportEnabled must be a boolean.');
  });

  it('setOrganizationFhirExportEnabled updates and logs', async () => {
    const result = await setOrganizationFhirExportEnabled.run(fakeCallableRequest({ fhirExportEnabled: true }, 'uid-1'));
    expect(mockOrgUpdate).toHaveBeenCalledWith({ fhirExportEnabled: true });
    expect(result).toEqual({ fhirExportEnabled: true });
  });
});

describe('listAuditLog', () => {
  it('throws permission-denied for a non-admin caller', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...ADMIN_PROFILE, role: ['ems'] });
    await expect(listAuditLog.run(fakeCallableRequest({}, 'uid-1'))).rejects.toThrow('Only admins can view the audit log.');
  });

  it('reports hasMore: false for a less-than-full page', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockAuditLogGet.mockResolvedValue({
      docs: [{ id: 'e1', data: () => ({ action: 'user.create', actorEmail: 'a@example.com', timestamp: FakeTimestamp.fromMillis(1000) }) }],
    });

    const result = await listAuditLog.run(fakeCallableRequest({}, 'uid-1'));

    expect(result.hasMore).toBe(false);
    expect(result.entries[0]).toEqual({
      id: 'e1',
      action: 'user.create',
      actorEmail: 'a@example.com',
      target: null,
      details: null,
      timestampMs: 1000,
    });
  });

  it('defaults action/actorEmail to empty strings when an entry is missing them', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockAuditLogGet.mockResolvedValue({ docs: [{ id: 'e1', data: () => ({}) }] });

    const result = await listAuditLog.run(fakeCallableRequest({}, 'uid-1'));

    expect(result.entries[0]).toEqual({
      id: 'e1',
      action: '',
      actorEmail: '',
      target: null,
      details: null,
      timestampMs: null,
    });
  });

  it('applies the beforeTimestampMs cursor for a "load more" page request', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    mockAuditLogGet.mockResolvedValue({ docs: [] });

    await listAuditLog.run(fakeCallableRequest({ beforeTimestampMs: 5000 }, 'uid-1'));

    // The query-chain mock's 'where' (the cursor branch) leads to the same
    // limit().get() as the no-cursor path — what matters here is that the
    // cursor branch runs at all without throwing, and still resolves via
    // the mocked query.
    expect(mockAuditLogGet).toHaveBeenCalledTimes(1);
  });

  it('reports hasMore: true for a full page (AUDIT_LOG_PAGE_SIZE entries)', async () => {
    mockGetCallerProfile.mockResolvedValue(ADMIN_PROFILE);
    const fullPage = Array.from({ length: 100 }, (_, i) => ({
      id: `e${i}`,
      data: () => ({ action: 'user.create', actorEmail: 'a@example.com', timestamp: null }),
    }));
    mockAuditLogGet.mockResolvedValue({ docs: fullPage });

    const result = await listAuditLog.run(fakeCallableRequest({}, 'uid-1'));

    expect(result.hasMore).toBe(true);
    expect(result.entries).toHaveLength(100);
  });
});

describe('cleanupCompletedPatients', () => {
  it('skips patients belonging to a retain-all-data organization', async () => {
    mockOrgsGet.mockResolvedValue({ docs: [{ id: 'org-retain', data: () => ({ retainAllData: true }) }] });
    mockPatientsWhereGet.mockResolvedValue({
      docs: [{ id: 'p1', ref: {}, data: () => ({ organizationId: 'org-retain' }) }],
    });

    await cleanupCompletedPatients.run({} as never);

    expect(mockBulkWriterDelete).not.toHaveBeenCalled();
    expect(mockLogAudit).not.toHaveBeenCalled();
    expect(mockBulkWriterClose).toHaveBeenCalledTimes(1);
  });

  it('deletes and logs (as SYSTEM_ACTOR) for a normal-retention organization', async () => {
    mockOrgsGet.mockResolvedValue({ docs: [] });
    const patientRef = {};
    mockPatientsWhereGet.mockResolvedValue({
      docs: [{ id: 'p1', ref: patientRef, data: () => ({ organizationId: 'org-1' }) }],
    });

    await cleanupCompletedPatients.run({} as never);

    expect(mockBulkWriterDelete).toHaveBeenCalledWith(patientRef);
    expect(mockLogAudit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'patient.delete', actor: { uid: 'system', email: 'Automated (retention policy)' } }),
    );
  });

  it('logs organizationId: undefined for a patient record with no (string) organizationId', async () => {
    mockOrgsGet.mockResolvedValue({ docs: [] });
    mockPatientsWhereGet.mockResolvedValue({
      docs: [{ id: 'p1', ref: {}, data: () => ({}) }],
    });

    await cleanupCompletedPatients.run({} as never);

    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ organizationId: undefined }));
  });
});
