import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';

export type UserRole = 'ems' | 'physician' | 'nurse' | 'admin';

let initialized = false;

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

// Accounts are admin-created only now — the login page has no
// self-registration path (an email with no account shows an error instead).
// This mirrors createUser in functions/src/index.ts closely enough for e2e
// purposes (a real admin also sets firstName/lastName/role at creation, but
// signUpAndOnboard's own subsequent steps already cover filling those in
// through the app itself), without needing an authenticated admin session
// to call the real callable.
export async function createPasswordlessAccount(email: string): Promise<string> {
  ensureInitialized();
  const user = await getAuth().createUser({ email });
  await getFirestore().doc(`users/${user.uid}`).set({ email }, { merge: true });
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

// Deletes any `hospitals` docs with this exact name via the Admin SDK.
// hospital-management.spec.ts also deletes its test hospital through the
// UI's own delete button as part of the flow it's testing, but that only
// runs if every earlier step in the test succeeds — this is an idempotent
// afterEach safety net (an empty query result is a no-op) so a mid-test
// failure can't leave a hospital doc behind. Looked up by name rather than
// id since the UI never exposes the Firestore-generated id directly.
export async function deleteHospitalByName(name: string): Promise<void> {
  ensureInitialized();
  const snapshot = await getFirestore().collection('hospitals').where('name', '==', name).get();
  await Promise.all(snapshot.docs.map((doc) => doc.ref.delete()));
}
