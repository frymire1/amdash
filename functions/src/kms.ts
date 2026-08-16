import * as crypto from 'crypto';
import { KeyManagementServiceClient } from '@google-cloud/kms';

// Toronto — matches Firestore's own `location` (firebase.json) and the
// app's REGION constant (shared.ts) everywhere else. Confirmed a valid
// Cloud KMS location (unlike Cloud Scheduler, which needs Montreal
// instead — see cleanupCompletedPatients in admin.ts — that's a
// Scheduler-specific constraint, not a KMS one).
const KMS_LOCATION = 'northamerica-northeast2';

// One shared ring; one CryptoKey per organization lives inside it (see
// getOrCreateOrgKey). Provisioned once, manually — see the plan's Phase 0
// runbook. Cloud Functions' runtime service account needs
// cloudkms.cryptoKeyEncrypterDecrypter + cloudkms.admin (or an
// equivalently-scoped custom role) granted on this ring specifically, not
// project-wide.
const KEY_RING_ID = 'patient-pii-ca';

const AES_KEY_LENGTH_BYTES = 32; // AES-256
const GCM_IV_LENGTH_BYTES = 12; // standard GCM nonce size

let client: KeyManagementServiceClient | null = null;
function kmsClient(): KeyManagementServiceClient {
  if (!client) client = new KeyManagementServiceClient();
  return client;
}

// The shape stored in Firestore in place of a plain string for any
// CMEK-encrypted field. `__enc: 1` is the shared detection contract —
// client and server code both check for its presence/value to tell an
// encrypted blob apart from a legacy/plain string, rather than guessing
// from raw JSON shape.
export interface EncryptedField {
  __enc: 1;
  alg: 'AES-256-GCM';
  keyName: string; // the org's CryptoKey resource name — self-contained, no extra org lookup needed to decrypt
  keyVersion: string; // which CryptoKeyVersion actually wrapped the DEK (bookkeeping for a future rewrap job)
  iv: string; // base64
  authTag: string; // base64
  ciphertext: string; // base64 — AES-256-GCM ciphertext of the plaintext field
  wrappedDek: string; // base64 — KMS Encrypt() output over the random per-record Data Encryption Key
}

export function isEncryptedField(value: unknown): value is EncryptedField {
  return typeof value === 'object' && value !== null && (value as { __enc?: unknown }).__enc === 1;
}

async function keyRingName(): Promise<string> {
  const projectId = await kmsClient().getProjectId();
  return kmsClient().keyRingPath(projectId, KMS_LOCATION, KEY_RING_ID);
}

// Idempotent: creates the org's dedicated CryptoKey on first call, returns
// its resource name on every call thereafter. One key per org (not one
// shared "Canada" key) — the ops cost is negligible once IAM is granted
// at the ring level (a new CryptoKey under an already-authorized ring
// needs no additional IAM work), and it buys two real things a shared key
// doesn't: a distinct Cloud KMS audit trail per org, and clean
// crypto-shredding (destroying one org's CryptoKeyVersion makes every doc
// encrypted under it permanently unrecoverable — a clean answer to a
// future "delete this org's PII" request without hunting down every
// Firestore doc).
export async function getOrCreateOrgKey(organizationId: string): Promise<string> {
  const ring = await keyRingName();
  const cryptoKeyId = `org-${organizationId}`;
  const name = `${ring}/cryptoKeys/${cryptoKeyId}`;

  try {
    const [existing] = await kmsClient().getCryptoKey({ name });
    if (existing.name) return existing.name;
  } catch (error) {
    if ((error as { code?: number }).code !== 5 /* NOT_FOUND */) throw error;
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  const ninetyDaysSeconds = 90 * 24 * 60 * 60;
  const [created] = await kmsClient().createCryptoKey({
    parent: ring,
    cryptoKeyId,
    cryptoKey: {
      purpose: 'ENCRYPT_DECRYPT',
      versionTemplate: { algorithm: 'GOOGLE_SYMMETRIC_ENCRYPTION' },
      // Automatic KEK rotation, for free — KMS's Decrypt API auto-detects
      // which CryptoKeyVersion wrapped a given ciphertext, so old wraps
      // keep decrypting forever without any companion rewrap job.
      rotationPeriod: { seconds: ninetyDaysSeconds },
      nextRotationTime: { seconds: nowSeconds + ninetyDaysSeconds },
    },
  });
  if (!created.name) {
    throw new Error(`Failed to create a Cloud KMS key for organization ${organizationId}.`);
  }
  return created.name;
}

// Envelope encryption: a random AES-256-GCM Data Encryption Key (DEK) per
// call encrypts the actual field; KMS only ever wraps/unwraps that DEK,
// never sees the plaintext field itself. Standard pattern — decouples the
// field-encryption algorithm from key management and avoids sending raw
// PII across KMS's network boundary on every read/write.
export async function encryptField(plaintext: string, keyName: string): Promise<EncryptedField> {
  const dek = crypto.randomBytes(AES_KEY_LENGTH_BYTES);
  const iv = crypto.randomBytes(GCM_IV_LENGTH_BYTES);

  const cipher = crypto.createCipheriv('aes-256-gcm', dek, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const authTag = cipher.getAuthTag();

  const [wrapped] = await kmsClient().encrypt({ name: keyName, plaintext: dek });
  if (!wrapped.ciphertext) {
    throw new Error('Cloud KMS did not return a wrapped key.');
  }

  return {
    __enc: 1,
    alg: 'AES-256-GCM',
    keyName,
    keyVersion: wrapped.name ?? '',
    iv: iv.toString('base64'),
    authTag: authTag.toString('base64'),
    ciphertext: ciphertext.toString('base64'),
    wrappedDek: Buffer.from(wrapped.ciphertext as Uint8Array).toString('base64'),
  };
}

// The field carries its own `keyName`, so decrypting never needs a
// separate org lookup — it's self-contained given just the blob.
export async function decryptField(field: EncryptedField): Promise<string> {
  const [unwrapped] = await kmsClient().decrypt({
    name: field.keyName,
    ciphertext: Buffer.from(field.wrappedDek, 'base64'),
  });
  if (!unwrapped.plaintext) {
    throw new Error('Cloud KMS did not return an unwrapped key.');
  }
  const dek = Buffer.from(unwrapped.plaintext as Uint8Array);

  const decipher = crypto.createDecipheriv('aes-256-gcm', dek, Buffer.from(field.iv, 'base64'));
  decipher.setAuthTag(Buffer.from(field.authTag, 'base64'));
  const plaintext = Buffer.concat([decipher.update(Buffer.from(field.ciphertext, 'base64')), decipher.final()]);
  return plaintext.toString('utf8');
}
