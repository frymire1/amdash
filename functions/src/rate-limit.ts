import * as crypto from 'crypto';
import { HttpsError } from 'firebase-functions/v2/https';
import { getFirestore } from 'firebase-admin/firestore';

// Throttles the handful of public, unauthenticated callables
// (checkAccountStatus/setInitialPassword/requestPasswordReset — see
// auth.ts) that have no `request.auth` to gate on at all. Deliberately not
// tied to Firebase App Check: App Check answers "is this my real app?"
// (caller *identity*), this answers "is the same caller hitting me too
// often?" (caller *behavior*) — a genuine copy of the real app can still be
// abuse. The two are independent defenses, not alternatives.
//
// Fixed-window counter, one Firestore doc per key, stored under a leading-
// underscore collection (`_rateLimits`) to signal "internal, no client ever
// touches this" — enforced explicitly in firestore.rules (defense in depth;
// the Admin SDK used here bypasses rules regardless).

const COLLECTION = '_rateLimits';

export interface RateLimitOptions {
  maxAttempts: number;
  windowMs: number;
}

// SHA-256 rather than the raw key as the document ID — the caller-supplied
// half of a key is usually an email address or IP, and neither belongs
// sitting in plaintext as a Firestore document identifier (visible in the
// console, in export tooling, in Cloud Logging) in a system built around not
// doing exactly that for patient data. Also sidesteps Firestore's own
// document-ID character restrictions for free, rather than hand-validating
// email/IP shapes against them.
function docIdFor(key: string): string {
  return crypto.createHash('sha256').update(key).digest('hex');
}

// Throws `HttpsError('resource-exhausted', ...)` once `key` has been hit
// `maxAttempts` times within the trailing `windowMs` — the caller should
// call this before doing any real work, and let the thrown error propagate
// straight out of the callable (the Flutter side's existing generic
// catch-and-show-a-message handling in login_screen.dart already renders
// this sensibly; no client-side change needed for a new error shape).
//
// Uses a transaction — not a plain get-then-set — so two requests for the
// same key landing in the same instant can't both read the same
// under-the-limit count and both be let through.
export async function enforceRateLimit(key: string, { maxAttempts, windowMs }: RateLimitOptions): Promise<void> {
  const ref = getFirestore().collection(COLLECTION).doc(docIdFor(key));
  const nowMs = Date.now();

  await getFirestore().runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    const data = snapshot.data();
    const windowStartMs = data?.['windowStartMs'] as number | undefined;
    const count = (data?.['count'] as number | undefined) ?? 0;

    const windowExpired = windowStartMs === undefined || nowMs - windowStartMs >= windowMs;
    if (windowExpired) {
      // A fresh window — this attempt is the first one in it, regardless of
      // whatever count an already-expired window left behind.
      transaction.set(ref, { windowStartMs: nowMs, count: 1 });
      return;
    }

    if (count >= maxAttempts) {
      throw new HttpsError('resource-exhausted', 'Too many attempts. Please try again later.');
    }

    transaction.set(ref, { windowStartMs, count: count + 1 });
  });
}
