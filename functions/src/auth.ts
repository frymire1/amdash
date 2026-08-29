import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { UserRole } from './classes/user-role';
import { CallerProfile } from './classes/caller-profile';
import { CheckAccountStatusRequest } from './classes/check-account-status-request';
import { SetInitialPasswordRequest } from './classes/set-initial-password-request';
import { RESEND_API_KEY, sendPasswordResetEmail, sendVerificationEmail } from './email';

initializeApp();

export const REGION = 'northamerica-northeast2';

// The one place every Cloud Function reads a caller's role/org — a single
// `users/{uid}` read, reused by every requireAdmin/requireSuperAdmin/manual
// role check below, rather than each function re-implementing its own
// lookup (that's what callerIsAdmin used to be, before organizations existed
// and a second field — organizationId — needed reading alongside role).
export async function getCallerProfile(uid: string | undefined): Promise<CallerProfile> {
  if (!uid) {
    throw new HttpsError('unauthenticated', 'You must be signed in.');
  }
  const snapshot = await getFirestore().collection('users').doc(uid).get();
  const data = snapshot.data();
  const role = data?.['role'];
  return {
    uid,
    email: data?.['email'] ?? '',
    role: Array.isArray(role) ? (role as UserRole[]) : [],
    organizationId: data?.['organizationId'],
  };
}

export async function findUserByEmail(email: string) {
  try {
    return await getAuth().getUserByEmail(email);
  } catch {
    throw new HttpsError('not-found', `No account found for ${email}.`);
  }
}

// Deliberately callable without being signed in — the login page uses this
// to decide, from just an email, whether to show a "set your password"
// screen (no account yet, or an admin-created account with no password) or
// a normal single-password sign-in screen. Returning `hasPassword` (rather
// than making the client guess from a failed sign-in attempt) is what lets
// the email-only-first flow work at all.
export const checkAccountStatus = onCall<CheckAccountStatusRequest>({ region: REGION }, async (request) => {
  const { email } = request.data;
  if (!email) {
    throw new HttpsError('invalid-argument', 'A valid email is required.');
  }

  try {
    const user = await getAuth().getUserByEmail(email);
    const hasPassword = user.providerData.some((provider) => provider.providerId === 'password');
    return { exists: true, hasPassword };
  } catch {
    return { exists: false, hasPassword: false };
  }
});

// Mirrors login_screen.dart's own _hasMinLength/_hasUppercase/_hasNumber/
// _hasSpecialChar checks exactly — that client-side checklist is only a UX
// guide, not an actual enforcement boundary, since setInitialPassword is a
// public, unauthenticated callable: anything bypassing the Flutter UI
// entirely (a direct HTTP call) could otherwise set an arbitrarily weak
// password. Keep both in sync if either changes.
const PASSWORD_MIN_LENGTH = 8;

function passwordMeetsComplexityRequirements(password: string): boolean {
  return (
    password.length >= PASSWORD_MIN_LENGTH &&
    /[A-Z]/.test(password) &&
    /[0-9]/.test(password) &&
    /[^A-Za-z0-9]/.test(password)
  );
}

// Deliberately callable without being signed in — the whole point is to let
// someone set their FIRST password before they've ever authenticated. This
// is safe only because of the check below: it flatly refuses to touch any
// account that already has a password credential, so it can never be used
// to take over an existing account just by knowing its email. An account
// that already has a password must go through "Forgot password?" instead,
// same as if this function didn't exist.
export const setInitialPassword = onCall<SetInitialPasswordRequest>({ region: REGION }, async (request) => {
  const { email, password } = request.data;
  if (!email || !password || !passwordMeetsComplexityRequirements(password)) {
    throw new HttpsError(
      'invalid-argument',
      'A valid email and a password of at least 8 characters, including an uppercase letter, a number, and a ' +
        'special character, are required.'
    );
  }

  const user = await findUserByEmail(email);

  const hasPassword = user.providerData.some((provider) => provider.providerId === 'password');
  if (hasPassword) {
    throw new HttpsError('already-exists', 'This account already has a password.');
  }

  await getAuth().updateUser(user.uid, { password });

  return { email: user.email };
});

// Both callables below read this off the target's own users/{uid} doc
// purely to personalize the email greeting — falls back to a generic
// greeting rather than throwing if it's somehow missing (every account
// gets one at createUser time, but this shouldn't block a reset/verify
// email over a cosmetic field).
async function firstNameFor(uid: string): Promise<string> {
  const doc = await getFirestore().collection('users').doc(uid).get();
  return doc.data()?.['firstName'] || 'there';
}

// Deliberately callable without being signed in, like checkAccountStatus
// above — this is what the login page's "Forgot password?" now calls
// instead of the Firebase Auth client SDK's own sendPasswordResetEmail
// (which both mints the reset link AND sends Firebase's own unbranded
// email for it, with no way to intercept just the delivery). Admin SDK's
// generatePasswordResetLink only mints the link; sending it is entirely
// on us, via the same Resend setup the welcome email uses. No
// actionCodeSettings passed — the link still lands on Firebase's own
// hosted reset-password page, unchanged from today's behavior.
//
// Deliberately does NOT use findUserByEmail — that helper throws a
// distinguishing 'not-found' error for an unregistered address, which is
// exactly right for checkAccountStatus's own email-first login flow (the
// whole point there is telling the client whether an account exists) but
// wrong here: "Forgot password?" throwing a different result for a real
// vs. fake email is a textbook account-enumeration side channel, and one a
// visitor doesn't already need to trigger the way they do for
// checkAccountStatus. Always returns the same generic { email } response
// either way — a real account gets its email exactly as before; a
// non-existent one silently no-ops.
export const requestPasswordReset = onCall<CheckAccountStatusRequest>(
  { region: REGION, secrets: [RESEND_API_KEY] },
  async (request) => {
    const { email } = request.data;
    if (!email) {
      throw new HttpsError('invalid-argument', 'A valid email is required.');
    }

    let user;
    try {
      user = await getAuth().getUserByEmail(email);
    } catch {
      return { email };
    }

    const firstName = await firstNameFor(user.uid);
    const resetUrl = await getAuth().generatePasswordResetLink(email);
    await sendPasswordResetEmail({ email, firstName, resetUrl });

    return { email };
  }
);

// Requires auth — this is what mfa_setup_screen.dart calls instead of the
// signed-in user's own currentUser.sendEmailVerification(), for the same
// reason requestPasswordReset replaces sendPasswordResetEmail above: the
// client SDK method sends Firebase's own unbranded email with no way to
// swap just the delivery.
export const requestEmailVerification = onCall({ region: REGION, secrets: [RESEND_API_KEY] }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  const firstName = await firstNameFor(profile.uid);
  const verifyUrl = await getAuth().generateEmailVerificationLink(profile.email);
  await sendVerificationEmail({ email: profile.email, firstName, verifyUrl });

  return { email: profile.email };
});
