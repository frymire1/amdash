import { beforeEach, describe, expect, it, vi } from 'vitest';

// @google-cloud/kms's client makes real network calls — mocked at the
// module level so encryptField/decryptField's own AES-256-GCM envelope
// logic (the actual thing worth testing here) runs for real while the
// "wrap/unwrap a DEK through Cloud KMS" step is faked. The encrypt/decrypt
// mocks below are wired as an identity function (return whatever bytes
// they were given) rather than anything KMS-specific — that's enough to
// prove a real encrypt-then-decrypt round trip through this file's own
// crypto code without needing a live KMS key.
//
// vi.hoisted() is required (not just top-level consts): vi.mock() factories
// are hoisted above every other statement in the file, so a factory that
// closes over an ordinary top-level const throws "Cannot access before
// initialization" — vi.hoisted() runs before that hoisting happens.
const { mockEncrypt, mockDecrypt, mockGetCryptoKey, mockCreateCryptoKey, mockGetProjectId, mockKeyRingPath } =
  vi.hoisted(() => ({
    mockEncrypt: vi.fn(),
    mockDecrypt: vi.fn(),
    mockGetCryptoKey: vi.fn(),
    mockCreateCryptoKey: vi.fn(),
    mockGetProjectId: vi.fn(),
    mockKeyRingPath: vi.fn(),
  }));

vi.mock('@google-cloud/kms', () => ({
  // A real `function` (not an arrow) assigning onto `this` — kms.ts calls
  // this with `new`, and an arrow-function mockImplementation can't act as
  // a constructor (JS itself throws "is not a constructor" for that,
  // independent of Vitest).
  KeyManagementServiceClient: vi.fn(function (this: Record<string, unknown>) {
    this['encrypt'] = mockEncrypt;
    this['decrypt'] = mockDecrypt;
    this['getCryptoKey'] = mockGetCryptoKey;
    this['createCryptoKey'] = mockCreateCryptoKey;
    this['getProjectId'] = mockGetProjectId;
    this['keyRingPath'] = mockKeyRingPath;
  }),
}));

import { decryptField, encryptField, getOrCreateOrgKey, isEncryptedField } from './kms';

describe('isEncryptedField', () => {
  it('recognizes a well-formed EncryptedField', () => {
    expect(
      isEncryptedField({
        __enc: 1,
        alg: 'AES-256-GCM',
        keyName: 'k',
        keyVersion: 'v',
        iv: 'i',
        authTag: 'a',
        ciphertext: 'c',
        wrappedDek: 'w',
      }),
    ).toBe(true);
  });

  it('rejects a plain string (the unencrypted/legacy case)', () => {
    expect(isEncryptedField('Jordan Smith')).toBe(false);
  });

  it('rejects null and undefined', () => {
    expect(isEncryptedField(null)).toBe(false);
    expect(isEncryptedField(undefined)).toBe(false);
  });

  it('rejects an object with no __enc field at all', () => {
    expect(isEncryptedField({ foo: 'bar' })).toBe(false);
  });

  it('rejects __enc values other than the literal 1 (including the string "1")', () => {
    expect(isEncryptedField({ __enc: 2 })).toBe(false);
    expect(isEncryptedField({ __enc: '1' })).toBe(false);
    expect(isEncryptedField({ __enc: true })).toBe(false);
  });
});

describe('encryptField / decryptField', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    // Identity "wrap": whatever DEK bytes encryptField hands KMS to wrap,
    // hand back unchanged as the wrapped ciphertext — decryptField's mock
    // below does the matching identity "unwrap", so the pair together
    // exercises a real AES-256-GCM round trip without a real KMS key.
    mockEncrypt.mockImplementation(async ({ plaintext }: { plaintext: Buffer }) => [
      { ciphertext: plaintext, name: 'projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1' },
    ]);
    mockDecrypt.mockImplementation(async ({ ciphertext }: { ciphertext: Buffer }) => [{ plaintext: ciphertext }]);
  });

  it('round-trips a plaintext string through envelope encryption unchanged', async () => {
    const encrypted = await encryptField('Jordan Smith', 'org-key-name');
    expect(encrypted.__enc).toBe(1);
    expect(encrypted.alg).toBe('AES-256-GCM');
    expect(encrypted.keyName).toBe('org-key-name');

    const decrypted = await decryptField(encrypted);
    expect(decrypted).toBe('Jordan Smith');
  });

  it('uses a fresh random DEK/IV per call — two encryptions of the same plaintext never match', async () => {
    const first = await encryptField('1234567890', 'org-key-name');
    const second = await encryptField('1234567890', 'org-key-name');
    expect(first.ciphertext).not.toBe(second.ciphertext);
    expect(first.iv).not.toBe(second.iv);
  });

  it('defaults keyVersion to an empty string when the wrap response omits a key-version name', async () => {
    mockEncrypt.mockImplementationOnce(async ({ plaintext }: { plaintext: Buffer }) => [{ ciphertext: plaintext, name: undefined }]);
    const encrypted = await encryptField('secret', 'org-key-name');
    expect(encrypted.keyVersion).toBe('');
  });

  it('throws if Cloud KMS does not return a wrapped key on encrypt', async () => {
    mockEncrypt.mockResolvedValueOnce([{ ciphertext: undefined }]);
    await expect(encryptField('secret', 'org-key-name')).rejects.toThrow('did not return a wrapped key');
  });

  it('throws if Cloud KMS does not return an unwrapped key on decrypt', async () => {
    const encrypted = await encryptField('secret', 'org-key-name');
    mockDecrypt.mockResolvedValueOnce([{ plaintext: undefined }]);
    await expect(decryptField(encrypted)).rejects.toThrow('did not return an unwrapped key');
  });
});

describe('getOrCreateOrgKey', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    mockGetProjectId.mockResolvedValue('amdash-dev');
    mockKeyRingPath.mockReturnValue('projects/amdash-dev/locations/northamerica-northeast2/keyRings/patient-pii-ca');
  });

  it('returns the existing key name without creating a new one when the key already exists', async () => {
    mockGetCryptoKey.mockResolvedValue([{ name: 'existing-key-name' }]);

    const result = await getOrCreateOrgKey('org-1');

    expect(result).toBe('existing-key-name');
    expect(mockCreateCryptoKey).not.toHaveBeenCalled();
  });

  it('creates a new key when getCryptoKey resolves successfully but with no name (falls through, same as NOT_FOUND)', async () => {
    mockGetCryptoKey.mockResolvedValue([{ name: undefined }]);
    mockCreateCryptoKey.mockResolvedValue([{ name: 'newly-created-key-name' }]);

    const result = await getOrCreateOrgKey('org-1b');

    expect(result).toBe('newly-created-key-name');
    expect(mockCreateCryptoKey).toHaveBeenCalledTimes(1);
  });

  it('creates a new key when getCryptoKey reports NOT_FOUND (code 5)', async () => {
    mockGetCryptoKey.mockRejectedValue({ code: 5 });
    mockCreateCryptoKey.mockResolvedValue([{ name: 'newly-created-key-name' }]);

    const result = await getOrCreateOrgKey('org-2');

    expect(result).toBe('newly-created-key-name');
    expect(mockCreateCryptoKey).toHaveBeenCalledWith(
      expect.objectContaining({ cryptoKeyId: 'org-org-2', parent: expect.any(String) }),
    );
  });

  it('re-throws a getCryptoKey error that is not NOT_FOUND, without attempting to create', async () => {
    mockGetCryptoKey.mockRejectedValue({ code: 7 /* PERMISSION_DENIED */ });

    await expect(getOrCreateOrgKey('org-3')).rejects.toEqual({ code: 7 });
    expect(mockCreateCryptoKey).not.toHaveBeenCalled();
  });

  it('throws if createCryptoKey does not return a name', async () => {
    mockGetCryptoKey.mockRejectedValue({ code: 5 });
    mockCreateCryptoKey.mockResolvedValue([{ name: undefined }]);

    await expect(getOrCreateOrgKey('org-4')).rejects.toThrow('Failed to create a Cloud KMS key');
  });
});
