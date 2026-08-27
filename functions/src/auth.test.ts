import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fakeCallableRequest } from './test-utils';

// vi.hoisted() is required (not plain top-level consts) — see
// audit.test.ts's comment for why.
const {
  mockInitializeApp,
  mockGetUserByEmail,
  mockUpdateUser,
  mockGeneratePasswordResetLink,
  mockGenerateEmailVerificationLink,
  mockGet,
  mockDoc,
  mockCollection,
  mockSendPasswordResetEmail,
  mockSendVerificationEmail,
} = vi.hoisted(() => ({
  mockInitializeApp: vi.fn(),
  mockGetUserByEmail: vi.fn(),
  mockUpdateUser: vi.fn(),
  mockGeneratePasswordResetLink: vi.fn(),
  mockGenerateEmailVerificationLink: vi.fn(),
  mockGet: vi.fn(),
  mockDoc: vi.fn(() => ({ get: mockGet })),
  mockCollection: vi.fn(() => ({ doc: mockDoc })),
  mockSendPasswordResetEmail: vi.fn(),
  mockSendVerificationEmail: vi.fn(),
}));

vi.mock('firebase-admin/app', () => ({ initializeApp: mockInitializeApp }));

vi.mock('firebase-admin/auth', () => ({
  getAuth: () => ({
    getUserByEmail: mockGetUserByEmail,
    updateUser: mockUpdateUser,
    generatePasswordResetLink: mockGeneratePasswordResetLink,
    generateEmailVerificationLink: mockGenerateEmailVerificationLink,
  }),
}));

vi.mock('firebase-admin/firestore', () => ({ getFirestore: () => ({ collection: mockCollection }) }));

vi.mock('./email', () => ({
  RESEND_API_KEY: 'fake-secret-param',
  sendPasswordResetEmail: mockSendPasswordResetEmail,
  sendVerificationEmail: mockSendVerificationEmail,
}));

import {
  checkAccountStatus,
  findUserByEmail,
  getCallerProfile,
  requestEmailVerification,
  requestPasswordReset,
  setInitialPassword,
} from './auth';

beforeEach(() => {
  vi.resetAllMocks();
});

describe('getCallerProfile', () => {
  it('throws unauthenticated when uid is undefined', async () => {
    await expect(getCallerProfile(undefined)).rejects.toThrow('You must be signed in.');
  });

  it('reads users/{uid} and returns the full profile', async () => {
    mockGet.mockResolvedValue({
      data: () => ({ email: 'a@example.com', role: ['physician'], organizationId: 'org-1' }),
    });

    const profile = await getCallerProfile('uid-1');

    expect(profile).toEqual({ uid: 'uid-1', email: 'a@example.com', role: ['physician'], organizationId: 'org-1' });
  });

  it('defaults email to empty string and role to [] when fields are missing/malformed', async () => {
    mockGet.mockResolvedValue({ data: () => ({}) });

    const profile = await getCallerProfile('uid-2');

    expect(profile.email).toBe('');
    expect(profile.role).toEqual([]);
    expect(profile.organizationId).toBeUndefined();
  });

  it('defaults role to [] when the field exists but is not an array', async () => {
    mockGet.mockResolvedValue({ data: () => ({ role: 'physician' }) });
    const profile = await getCallerProfile('uid-3');
    expect(profile.role).toEqual([]);
  });
});

describe('findUserByEmail', () => {
  it('returns the Auth user record on success', async () => {
    mockGetUserByEmail.mockResolvedValue({ uid: 'uid-1', email: 'a@example.com' });
    const user = await findUserByEmail('a@example.com');
    expect(user).toEqual({ uid: 'uid-1', email: 'a@example.com' });
  });

  it('throws a not-found HttpsError when no account exists', async () => {
    mockGetUserByEmail.mockRejectedValue(new Error('no user'));
    await expect(findUserByEmail('nobody@example.com')).rejects.toThrow('No account found for nobody@example.com.');
  });
});

describe('checkAccountStatus', () => {
  it('throws invalid-argument when email is missing', async () => {
    await expect(checkAccountStatus.run(fakeCallableRequest({ email: '' }))).rejects.toThrow(
      'A valid email is required.',
    );
  });

  it('reports exists: true, hasPassword: true for an account with a password provider', async () => {
    mockGetUserByEmail.mockResolvedValue({ providerData: [{ providerId: 'password' }] });
    const result = await checkAccountStatus.run(fakeCallableRequest({ email: 'a@example.com' }));
    expect(result).toEqual({ exists: true, hasPassword: true });
  });

  it('reports exists: true, hasPassword: false for an account with no password provider (e.g. admin-created)', async () => {
    mockGetUserByEmail.mockResolvedValue({ providerData: [] });
    const result = await checkAccountStatus.run(fakeCallableRequest({ email: 'a@example.com' }));
    expect(result).toEqual({ exists: true, hasPassword: false });
  });

  it('reports exists: false when no account is found at all', async () => {
    mockGetUserByEmail.mockRejectedValue(new Error('no user'));
    const result = await checkAccountStatus.run(fakeCallableRequest({ email: 'nobody@example.com' }));
    expect(result).toEqual({ exists: false, hasPassword: false });
  });
});

describe('setInitialPassword', () => {
  it('throws invalid-argument for a missing email, missing password, or too-short password', async () => {
    await expect(
      setInitialPassword.run(fakeCallableRequest({ email: '', password: 'longenough' })),
    ).rejects.toThrow();
    await expect(setInitialPassword.run(fakeCallableRequest({ email: 'a@example.com', password: '' }))).rejects.toThrow();
    await expect(
      setInitialPassword.run(fakeCallableRequest({ email: 'a@example.com', password: 'abc' })),
    ).rejects.toThrow('at least 6 characters');
  });

  it('refuses an account that already has a password — this is a first-password-only flow', async () => {
    mockGetUserByEmail.mockResolvedValue({ uid: 'uid-1', providerData: [{ providerId: 'password' }] });

    await expect(
      setInitialPassword.run(fakeCallableRequest({ email: 'a@example.com', password: 'longenough' })),
    ).rejects.toThrow('This account already has a password.');
    expect(mockUpdateUser).not.toHaveBeenCalled();
  });

  it('sets the password for an account with none yet, and returns its email', async () => {
    mockGetUserByEmail.mockResolvedValue({ uid: 'uid-1', email: 'a@example.com', providerData: [] });

    const result = await setInitialPassword.run(
      fakeCallableRequest({ email: 'a@example.com', password: 'longenough' }),
    );

    expect(mockUpdateUser).toHaveBeenCalledWith('uid-1', { password: 'longenough' });
    expect(result).toEqual({ email: 'a@example.com' });
  });
});

describe('requestPasswordReset', () => {
  it('throws invalid-argument when email is missing', async () => {
    await expect(requestPasswordReset.run(fakeCallableRequest({ email: '' }))).rejects.toThrow(
      'A valid email is required.',
    );
  });

  it('finds the user, mints a reset link, and sends it — falling back to a generic first name', async () => {
    mockGetUserByEmail.mockResolvedValue({ uid: 'uid-1', email: 'a@example.com', providerData: [] });
    mockGet.mockResolvedValue({ data: () => ({}) }); // no firstName on the users/{uid} doc
    mockGeneratePasswordResetLink.mockResolvedValue('https://reset.link');

    const result = await requestPasswordReset.run(fakeCallableRequest({ email: 'a@example.com' }));

    expect(mockSendPasswordResetEmail).toHaveBeenCalledWith({
      email: 'a@example.com',
      firstName: 'there',
      resetUrl: 'https://reset.link',
    });
    expect(result).toEqual({ email: 'a@example.com' });
  });

  it('uses the real first name when the users/{uid} doc has one', async () => {
    mockGetUserByEmail.mockResolvedValue({ uid: 'uid-1', email: 'a@example.com', providerData: [] });
    mockGet.mockResolvedValue({ data: () => ({ firstName: 'Jordan' }) });
    mockGeneratePasswordResetLink.mockResolvedValue('https://reset.link');

    await requestPasswordReset.run(fakeCallableRequest({ email: 'a@example.com' }));

    expect(mockSendPasswordResetEmail).toHaveBeenCalledWith(
      expect.objectContaining({ firstName: 'Jordan' }),
    );
  });
});

describe('requestEmailVerification', () => {
  it('requires auth (reads the caller from request.auth.uid, unlike the two callables above)', async () => {
    mockGet.mockResolvedValue({ data: () => ({ email: 'a@example.com', firstName: 'Jordan' }) });
    mockGenerateEmailVerificationLink.mockResolvedValue('https://verify.link');

    const result = await requestEmailVerification.run(fakeCallableRequest({}, 'uid-1'));

    expect(mockSendVerificationEmail).toHaveBeenCalledWith({
      email: 'a@example.com',
      firstName: 'Jordan',
      verifyUrl: 'https://verify.link',
    });
    expect(result).toEqual({ email: 'a@example.com' });
  });

  it('throws unauthenticated when there is no signed-in caller', async () => {
    await expect(requestEmailVerification.run(fakeCallableRequest({}))).rejects.toThrow('You must be signed in.');
  });
});
