import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';

export type UserRole = 'ems' | 'physician' | 'nurse' | 'admin' | 'super-admin';

let initialized = false;
let cachedTestOrganizationId: string | undefined;

// Grants Admin SDK access by reusing whatever account is already logged
// into the Firebase CLI on this machine (`firebase login`), converting its
// cached OAuth refresh token into an Application Default Credentials file —
// the same technique `firebase functions:shell`/emulators use to give local
// code real project access. Roles can only ever be set server-side (see
// firestore.rules and the setUserRole Cloud Function), so there's no
// client-only way for a test to grant itself a role; this is what lets the
// e2e suite do it without real user credentials. Requires the machine
// running these tests to have an authenticated `firebase login` session —
// except when GOOGLE_APPLICATION_CREDENTIALS is already set externally (CI
// sets it to a real service-account key file — see
// .github/workflows/ci.yml), which the Admin SDK auto-detects on its own, so
// the local-credential derivation below is skipped entirely.
function ensureInitialized() {
  if (initialized) {
    return;
  }

  if (process.env['GOOGLE_APPLICATION_CREDENTIALS']) {
    initializeApp({ projectId: 'amdash-dev' });
    initialized = true;
    return;
  }

  const firebaseToolsConfigPath = path.join(os.homedir(), '.config/configstore/firebase-tools.json');
  const { tokens } = JSON.parse(fs.readFileSync(firebaseToolsConfigPath, 'utf8'));

  // firebase-tools' public OAuth client — not a secret, it's the same
  // client id/secret embedded in the open-source CLI itself.
  const credential = {
    client_id: '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com',
    client_secret: 'j9iVZfS8kkCEFUPaAeJV0sAi',
    refresh_token: tokens.refresh_token,
    type: 'authorized_user',
  };

  const credentialPath = path.join(os.tmpdir(), `amdash-e2e-adc-${process.pid}.json`);
  fs.writeFileSync(credentialPath, JSON.stringify(credential));
  process.env['GOOGLE_APPLICATION_CREDENTIALS'] = credentialPath;

  initializeApp({ projectId: 'amdash-dev' });
  initialized = true;
}

// A one-time migration created this once, for real, in amdash-dev, when
// organizations were introduced. Every e2e fixture account lands inside it
// rather than a fresh empty org per test — physician-e2e/admin-e2e reference
// the seeded hospital "General Hospital" by name, which only exists in
// test-org, so a fresh empty org would make those tests fail with zero
// visible hospitals.
async function getTestOrganizationId(): Promise<string> {
  if (cachedTestOrganizationId) {
    return cachedTestOrganizationId;
  }
  ensureInitialized();
  const snapshot = await getFirestore().collection('organizations').where('name', '==', 'test-org').get();
  if (snapshot.empty) {
    throw new Error('No "test-org" organization found in amdash-dev — has it been reset since organizations were introduced?');
  }
  cachedTestOrganizationId = snapshot.docs[0].id;
  return cachedTestOrganizationId;
}

// Accounts are admin-created only now — the login page has no
// self-registration path (an email with no account shows an error instead).
// This mirrors createUser in functions/src/index.ts closely enough for e2e
// purposes (a real admin also sets firstName/lastName/role at creation, but
// signUpAndOnboard's own subsequent steps already cover filling those in
// through the app itself), without needing an authenticated admin session
// to call the real callable.
export async function createPasswordlessAccount(email: string): Promise<string> {
  ensureInitialized();
  const organizationId = await getTestOrganizationId();
  const user = await getAuth().createUser({ email });
  await getFirestore().doc(`users/${user.uid}`).set({ email, organizationId }, { merge: true });
  return user.uid;
}

// Creates a real, ready-to-sign-in account directly via the Admin SDK — with
// a password and role already set, unlike createPasswordlessAccount above —
// so a test only needs the real Sign In flow to reach an app route, skipping
// every UI-driven write (Set Password, saveProfile) that reaching it would
// otherwise require. That matters specifically for a test that forces some
// *other*, later Firestore write to fail via network interception: Firestore's
// Write WebChannel is a long-lived, multiplexed connection the client keeps
// open and reuses once established, so a route interception registered right
// before a second write in the same session can silently miss it — the
// write goes out over the already-open connection from an earlier,
// unintercepted write instead of a fresh request the interception would
// catch. (This is exactly what let saveWorkLocation's write through despite
// an aborted route, in a test that first drove a real saveProfile()
// through user-settings.) Skipping every real write before the one under
// test guarantees there's no such connection yet to reuse.
export async function createAccountWithPassword(email: string, password: string, role: UserRole): Promise<string> {
  ensureInitialized();
  const organizationId = await getTestOrganizationId();
  const user = await getAuth().createUser({ email, password });
  await getFirestore().doc(`users/${user.uid}`).set({ email, role: [role], organizationId }, { merge: true });
  return user.uid;
}

// Adds a role Firestore rules otherwise forbid clients from setting on
// themselves, so an e2e-created account can pass the app's role guards
// (physicianAppGuard / emsAppGuard / adminGuard). `role` is an array — a
// user can hold more than one — so this unions in rather than overwrites,
// matching setUserRole's semantics in functions/src/index.ts.
export async function grantRole(email: string, role: UserRole): Promise<void> {
  ensureInitialized();
  const user = await getAuth().getUserByEmail(email);
  await getFirestore()
    .doc(`users/${user.uid}`)
    .set({ role: FieldValue.arrayUnion(role) }, { merge: true });
}

// Deletes a throwaway e2e account's `users/{uid}` Firestore doc and its
// Firebase Auth record via the Admin SDK, rather than signing in as the
// account (as a client would) to do it through the client SDK/REST API.
// Signing in requires a password, which won't exist yet if a test failed
// before its onboarding flow reached the "Set Password" step — the Admin SDK
// route works regardless of how far onboarding got.
export async function deleteAccountByEmail(email: string): Promise<void> {
  ensureInitialized();
  const user = await getAuth().getUserByEmail(email);
  await getFirestore().doc(`users/${user.uid}`).delete();
  await getAuth().deleteUser(user.uid);
}

// Deletes the `patients/{patientId}` and `emsLocations/{patientId}` docs an
// e2e test created, via the Admin SDK. Firestore deletes are idempotent, so
// this is safe to call even if one or both docs were never created, or were
// already removed through the app's own UI during the test.
export async function deletePatientData(patientId: string): Promise<void> {
  ensureInitialized();
  await Promise.all([
    getFirestore().doc(`patients/${patientId}`).delete(),
    getFirestore().doc(`emsLocations/${patientId}`).delete(),
  ]);
}
