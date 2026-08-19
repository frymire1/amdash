import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { UserRole } from './classes/user-role';
import { CallerProfile } from './classes/caller-profile';
import { CheckAccountStatusRequest } from './classes/check-account-status-request';
import { SetInitialPasswordRequest } from './classes/set-initial-password-request';

initializeApp();

export const REGION = 'northamerica-northeast2';

// patients/{patientId}/location/current — the one place a patient's live
// GPS position lives (written by ems.ts's onEmsLocationEvent for every
// ongoing fix, and patients.ts's uploadPatientDocument for the very first
// one). A subcollection rather than a field on the patient doc itself, and
// rather than its own top-level collection: a sibling document means every
// ~15s GPS tick never fires onPatientUpdated's audit trigger or re-emits
// the patients-collection listener the whole patient list watches (a
// Firestore subcollection write is invisible to both), while still living
// naturally alongside the patient it belongs to. Read org-wide via a
// collectionGroup('location') query (see EmsLocationController on the
// physician client) rather than a per-patient listener each.
export function patientLocationRef(patientId: string) {
  return getFirestore().collection('patients').doc(patientId).collection('location').doc('current');
}

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

// Deliberately callable without being signed in — the whole point is to let
// someone set their FIRST password before they've ever authenticated. This
// is safe only because of the check below: it flatly refuses to touch any
// account that already has a password credential, so it can never be used
// to take over an existing account just by knowing its email. An account
// that already has a password must go through "Forgot password?" instead,
// same as if this function didn't exist.
export const setInitialPassword = onCall<SetInitialPasswordRequest>({ region: REGION }, async (request) => {
  const { email, password } = request.data;
  if (!email || !password || password.length < 6) {
    throw new HttpsError('invalid-argument', 'A valid email and a password of at least 6 characters are required.');
  }

  const user = await findUserByEmail(email);

  const hasPassword = user.providerData.some((provider) => provider.providerId === 'password');
  if (hasPassword) {
    throw new HttpsError('already-exists', 'This account already has a password.');
  }

  await getAuth().updateUser(user.uid, { password });

  return { email: user.email };
});
