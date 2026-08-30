import { beforeEach, describe, expect, it, vi } from 'vitest';

// vi.hoisted() is required (not plain top-level consts) — see
// audit.test.ts's comment for why.
const { mockCollection, mockDoc, mockRunTransaction, mockTransactionGet, mockTransactionSet } = vi.hoisted(() => ({
  mockCollection: vi.fn(() => ({ doc: mockDoc })),
  mockDoc: vi.fn((id: string) => ({ id })),
  mockRunTransaction: vi.fn(),
  mockTransactionGet: vi.fn(),
  mockTransactionSet: vi.fn(),
}));

vi.mock('firebase-admin/firestore', () => ({
  getFirestore: () => ({ collection: mockCollection, runTransaction: mockRunTransaction }),
}));

import { enforceRateLimit } from './rate-limit';

// runTransaction's real behavior: call the update function with a
// transaction object, and resolve/reject with whatever that function
// returns/throws. Mirrored here so enforceRateLimit's own transaction body
// runs for real against the mocked get/set below.
function stubTransaction(existingData: Record<string, unknown> | undefined) {
  mockTransactionGet.mockResolvedValue({ data: () => existingData });
  mockRunTransaction.mockImplementation(async (updateFn: (transaction: unknown) => Promise<void>) =>
    updateFn({ get: mockTransactionGet, set: mockTransactionSet }),
  );
}

describe('enforceRateLimit', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('the first-ever call for a key succeeds and starts a fresh window', async () => {
    stubTransaction(undefined);

    await expect(enforceRateLimit('key-1', { maxAttempts: 3, windowMs: 60_000 })).resolves.toBeUndefined();

    expect(mockTransactionSet).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ count: 1 }),
    );
  });

  it('a call under the limit succeeds and increments the existing count', async () => {
    stubTransaction({ windowStartMs: Date.now(), count: 1 });

    await expect(enforceRateLimit('key-1', { maxAttempts: 3, windowMs: 60_000 })).resolves.toBeUndefined();

    expect(mockTransactionSet).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ count: 2 }),
    );
  });

  it('a call at the limit is rejected and does not increment the stored count', async () => {
    stubTransaction({ windowStartMs: Date.now(), count: 3 });

    await expect(enforceRateLimit('key-1', { maxAttempts: 3, windowMs: 60_000 })).rejects.toThrow(
      'Too many attempts. Please try again later.',
    );

    expect(mockTransactionSet).not.toHaveBeenCalled();
  });

  it('a call past the limit (count already above maxAttempts) is also rejected', async () => {
    stubTransaction({ windowStartMs: Date.now(), count: 9 });

    await expect(enforceRateLimit('key-1', { maxAttempts: 3, windowMs: 60_000 })).rejects.toThrow(
      'Too many attempts. Please try again later.',
    );
  });

  it('a call after the window has expired resets to a fresh window, even if the old count was over the limit', async () => {
    stubTransaction({ windowStartMs: Date.now() - 120_000, count: 99 });

    await expect(enforceRateLimit('key-1', { maxAttempts: 3, windowMs: 60_000 })).resolves.toBeUndefined();

    expect(mockTransactionSet).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ count: 1 }),
    );
  });

  it('a call exactly at the window boundary is treated as expired (>=, not >)', async () => {
    stubTransaction({ windowStartMs: Date.now() - 60_000, count: 3 });

    await expect(enforceRateLimit('key-1', { maxAttempts: 3, windowMs: 60_000 })).resolves.toBeUndefined();
  });

  it('different keys hash to different document IDs, so one never contends with another', async () => {
    stubTransaction(undefined);

    await enforceRateLimit('key-a', { maxAttempts: 3, windowMs: 60_000 });
    const firstDocId = mockDoc.mock.calls[0][0];
    await enforceRateLimit('key-b', { maxAttempts: 3, windowMs: 60_000 });
    const secondDocId = mockDoc.mock.calls[1][0];

    expect(firstDocId).not.toEqual(secondDocId);
  });

  it('the same key hashes to the same document ID every time', async () => {
    stubTransaction(undefined);

    await enforceRateLimit('same-key', { maxAttempts: 3, windowMs: 60_000 });
    await enforceRateLimit('same-key', { maxAttempts: 3, windowMs: 60_000 });

    expect(mockDoc.mock.calls[0][0]).toEqual(mockDoc.mock.calls[1][0]);
  });
});
