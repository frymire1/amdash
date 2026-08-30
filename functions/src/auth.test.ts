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
  mockEnforceRateLimit,
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
  // rate-limit.ts has its own dedicated test file covering its internals
  // (window math, transaction semantics, key hashing) — mocked away here,
  // same as email.ts below, so these tests stay focused on auth.ts's own
  // logic and don't need a Firestore transaction mock on top of everything
  // else already being stubbed.
  mockEnforceRateLimit: vi.fn(),
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

vi.mock('./rate-limit', () => ({ enforceRateLimit: mockEnforceRateLimit }));

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

  it('rate-limits per caller IP before doing any lookup', async () => {
    mockGetUserByEmail.mockResolvedValue({ providerData: [] });

    await checkAccountStatus.run(fakeCallableRequest({ email: 'a@example.com' }));

    expect(mockEnforceRateLimit).toHaveBeenCalledWith(expect.stringContaining('check:ip:'), {
      maxAttempts: 20,
      windowMs: 60 * 60 * 1000,
    });
  });

  it('propagates a rate-limit rejection instead of performing the lookup', async () => {
    mockEnforceRateLimit.mockRejectedValue(new Error('Too many attempts. Please try again later.'));

    await expect(checkAccountStatus.run(fakeCallableRequest({ email: 'a@example.com' }))).rejects.toThrow(
      'Too many attempts',
    );
    expect(mockGetUserByEmail).not.toHaveBeenCalled();
  });
});

describe('setInitialPassword', () => {
  it('throws invalid-argument for a missing email or missing password', async () => {
    await expect(
      setInitialPassword.run(fakeCallableRequest({ email: '', password: 'Longenough1!' })),
    ).rejects.toThrow();
    await expect(setInitialPassword.run(fakeCallableRequest({ email: 'a@example.com', password: '' }))).rejects.toThrow();
  });

  // Mirrors login_screen.dart's own 4 client-side checklist items — the
  // client-side checklist is only a UX guide, not the actual enforcement
  // boundary, since this is a public, unauthenticated callable a request
  // could reach directly, bypassing the Flutter UI (and its checklist)
  // entirely.
  it.each([
    ['too short overall', 'Short1!'],
    ['no uppercase letter', 'longenough1!'],
    ['no number', 'Longenough!'],
    ['no special character', 'Longenough1'],
  ])('rejects a password that does not meet the complexity requirements: %s', async (_label, password) => {
    await expect(
      setInitialPassword.run(fakeCallableRequest({ email: 'a@example.com', password })),
    ).rejects.toThrow('at least 8 characters');
    expect(mockUpdateUser).not.toHaveBeenCalled();
  });

  it('refuses an account that already has a password — this is a first-password-only flow', async () => {
    mockGetUserByEmail.mockResolvedValue({ uid: 'uid-1', providerData: [{ providerId: 'password' }] });

    await expect(
      setInitialPassword.run(fakeCallableRequest({ email: 'a@example.com', password: 'Longenough1!' })),
    ).rejects.toThrow('This account already has a password.');
    expect(mockUpdateUser).not.toHaveBeenCalled();
  });

  it('sets the password for an account with none yet, and returns its email', async () => {
    mockGetUserByEmail.mockResolvedValue({ uid: 'uid-1', email: 'a@example.com', providerData: [] });

    const result = await setInitialPassword.run(
      fakeCallableRequest({ email: 'a@example.com', password: 'Longenough1!' }),
    );

    expect(mockUpdateUser).toHaveBeenCalledWith('uid-1', { password: 'Longenough1!' });
    expect(result).toEqual({ email: 'a@example.com' });
  });

  it('rate-limits per caller IP and per target email before touching the account', async () => {
    mockGetUserByEmail.mockResolvedValue({ uid: 'uid-1', email: 'a@example.com', providerData: [] });

    await setInitialPassword.run(fakeCallableRequest({ email: 'a@example.com', password: 'Longenough1!' }));

    expect(mockEnforceRateLimit).toHaveBeenCalledWith(expect.stringContaining('setpw:ip:'), {
      maxAttempts: 5,
      windowMs: 60 * 60 * 1000,
    });
    expect(mockEnforceRateLimit).toHaveBeenCalledWith('setpw:email:a@example.com', {
      maxAttempts: 5,
      windowMs: 60 * 60 * 1000,
    });
  });

  it('propagates a rate-limit rejection instead of setting a password', async () => {
    mockEnforceRateLimit.mockRejectedValue(new Error('Too many attempts. Please try again later.'));

    await expect(
      setInitialPassword.run(fakeCallableRequest({ email: 'a@example.com', password: 'Longenough1!' })),
    ).rejects.toThrow('Too many attempts');
    expect(mockUpdateUser).not.toHaveBeenCalled();
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

  // Regression test for a real account-enumeration gap: this used to call
  // findUserByEmail, which throws a distinguishing 'not-found' error for an
  // unregistered address — letting anyone tell which emails have accounts
  // just by watching whether "Forgot password?" succeeds or fails. It must
  // now return the exact same generic response either way, and do no
  // actual work (no link minted, no email sent) for an address with no
  // account.
  it('a non-existent account gets the same generic response, silently, with no email sent', async () => {
    mockGetUserByEmail.mockRejectedValue(new Error('no user'));

    const result = await requestPasswordReset.run(fakeCallableRequest({ email: 'nobody@example.com' }));

    expect(result).toEqual({ email: 'nobody@example.com' });
    expect(mockGeneratePasswordResetLink).not.toHaveBeenCalled();
    expect(mockSendPasswordResetEmail).not.toHaveBeenCalled();
  });

  it('rate-limits per target email and per caller IP, even for a non-existent account', async () => {
    mockGetUserByEmail.mockRejectedValue(new Error('no user'));

    await requestPasswordReset.run(fakeCallableRequest({ email: 'nobody@example.com' }));

    expect(mockEnforceRateLimit).toHaveBeenCalledWith('reset:email:nobody@example.com', {
      maxAttempts: 3,
      windowMs: 60 * 60 * 1000,
    });
    expect(mockEnforceRateLimit).toHaveBeenCalledWith(expect.stringContaining('reset:ip:'), {
      maxAttempts: 20,
      windowMs: 60 * 60 * 1000,
    });
  });

  it('propagates a rate-limit rejection instead of sending anything', async () => {
    mockEnforceRateLimit.mockRejectedValue(new Error('Too many attempts. Please try again later.'));

    await expect(requestPasswordReset.run(fakeCallableRequest({ email: 'a@example.com' }))).rejects.toThrow(
      'Too many attempts',
    );
    expect(mockSendPasswordResetEmail).not.toHaveBeenCalled();
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
