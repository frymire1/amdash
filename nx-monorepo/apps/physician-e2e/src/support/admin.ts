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
// running these tests to have an authenticated `firebase login` session.
function ensureInitialized() {
  if (initialized) {
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
