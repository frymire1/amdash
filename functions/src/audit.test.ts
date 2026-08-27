import { beforeEach, describe, expect, it, vi } from 'vitest';

// vi.hoisted() is required here (not plain top-level consts): vi.mock()
// factories are hoisted above every other statement in the file, so a
// factory closing over an ordinary top-level const throws "Cannot access
// before initialization" — vi.hoisted() runs before that hoisting happens.
const { mockGet, mockAdd, mockDoc, mockCollection, mockLoggerError } = vi.hoisted(() => {
  const mockGet = vi.fn();
  const mockAdd = vi.fn();
  const mockDoc = vi.fn(() => ({ get: mockGet }));
  const mockCollection = vi.fn(() => ({ doc: mockDoc, add: mockAdd }));
  const mockLoggerError = vi.fn();
  return { mockGet, mockAdd, mockDoc, mockCollection, mockLoggerError };
});

vi.mock('firebase-admin/firestore', () => ({
  getFirestore: () => ({ collection: mockCollection }),
  FieldValue: { serverTimestamp: vi.fn(() => 'SERVER_TIMESTAMP') },
}));

vi.mock('firebase-functions/v2', () => ({
  logger: { error: mockLoggerError },
}));

import { SYSTEM_ACTOR, logAudit, resolveActor } from './audit';

const ACTOR = { uid: 'actor-uid', email: 'actor@example.com' };

describe('logAudit', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    mockAdd.mockResolvedValue(undefined);
  });

  it('writes directly for an ungated action, without checking org settings first', async () => {
    await logAudit({ action: 'user.create', actor: ACTOR, organizationId: 'org-1', target: 'user-2' });

    // 'user.create' isn't in GATED_ACTIONS, so the only collection() call
    // should be the write itself — no organizations lookup at all.
    expect(mockCollection).toHaveBeenCalledTimes(1);
    expect(mockCollection).toHaveBeenCalledWith('auditLog');
    expect(mockAdd).toHaveBeenCalledWith({
      action: 'user.create',
      actorUid: 'actor-uid',
      actorEmail: 'actor@example.com',
      organizationId: 'org-1',
      target: 'user-2',
      details: null,
      timestamp: 'SERVER_TIMESTAMP',
    });
  });

  it('skips the write for a gated action when the org has explicitly disabled audit logging', async () => {
    mockGet.mockResolvedValue({ data: () => ({ auditLoggingEnabled: false }) });

    await logAudit({ action: 'patient.create', actor: ACTOR, organizationId: 'org-1' });

    expect(mockAdd).not.toHaveBeenCalled();
  });

  it('writes for a gated action when the org has audit logging on', async () => {
    mockGet.mockResolvedValue({ data: () => ({ auditLoggingEnabled: true }) });

    await logAudit({ action: 'patient.decrypt', actor: ACTOR, organizationId: 'org-1', target: 'patient-1' });

    expect(mockAdd).toHaveBeenCalledTimes(1);
  });

  it('defaults to enabled when the org predates the toggle (field missing entirely)', async () => {
    mockGet.mockResolvedValue({ data: () => ({}) });

    await logAudit({ action: 'patient.fhirExport', actor: ACTOR, organizationId: 'org-1' });

    expect(mockAdd).toHaveBeenCalledTimes(1);
  });

  it('skips the org-settings check entirely (and still writes) when organizationId is undefined', async () => {
    await logAudit({ action: 'patient.complete', actor: ACTOR, organizationId: undefined });

    expect(mockCollection).toHaveBeenCalledTimes(1);
    expect(mockCollection).toHaveBeenCalledWith('auditLog');
    expect(mockAdd).toHaveBeenCalledWith(expect.objectContaining({ organizationId: null }));
  });

  it('is best-effort: swallows a Firestore write failure and logs it instead of throwing', async () => {
    mockAdd.mockRejectedValue(new Error('Firestore is down'));

    await expect(logAudit({ action: 'user.delete', actor: ACTOR, organizationId: undefined })).resolves.toBeUndefined();
    expect(mockLoggerError).toHaveBeenCalledWith('Failed to write audit log entry', expect.any(Object));
  });

  it('defaults target/details to null when omitted', async () => {
    await logAudit({ action: 'hospital.create', actor: ACTOR, organizationId: undefined });

    expect(mockAdd).toHaveBeenCalledWith(expect.objectContaining({ target: null, details: null }));
  });
});

describe('resolveActor', () => {
  beforeEach(() => {
    vi.resetAllMocks();
  });

  it('returns unknown/unknown without touching Firestore for a non-string uid', async () => {
    expect(await resolveActor(undefined)).toEqual({ uid: 'unknown', email: 'unknown' });
    expect(await resolveActor(123)).toEqual({ uid: 'unknown', email: 'unknown' });
    expect(mockCollection).not.toHaveBeenCalled();
  });

  it('returns unknown/unknown for an empty string uid', async () => {
    expect(await resolveActor('')).toEqual({ uid: 'unknown', email: 'unknown' });
  });

  it('resolves the email from users/{uid} when it exists and is a string', async () => {
    mockGet.mockResolvedValue({ data: () => ({ email: 'real@example.com' }) });

    expect(await resolveActor('uid-1')).toEqual({ uid: 'uid-1', email: 'real@example.com' });
    expect(mockCollection).toHaveBeenCalledWith('users');
  });

  it('falls back to unknown when the user doc has no email field', async () => {
    mockGet.mockResolvedValue({ data: () => ({}) });
    expect(await resolveActor('uid-2')).toEqual({ uid: 'uid-2', email: 'unknown' });
  });

  it('falls back to unknown when the email field is not a string', async () => {
    mockGet.mockResolvedValue({ data: () => ({ email: 12345 }) });
    expect(await resolveActor('uid-3')).toEqual({ uid: 'uid-3', email: 'unknown' });
  });

  it('falls back to unknown/unknown (not a throw) when the Firestore read fails', async () => {
    mockGet.mockRejectedValue(new Error('offline'));
    expect(await resolveActor('uid-4')).toEqual({ uid: 'uid-4', email: 'unknown' });
  });
});

describe('SYSTEM_ACTOR', () => {
  it('is the fixed pseudo-actor used for scheduled-job audit entries', () => {
    expect(SYSTEM_ACTOR).toEqual({ uid: 'system', email: 'Automated (retention policy)' });
  });
});
