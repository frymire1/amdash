import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';

let initialized = false;

// Grants Admin SDK access by reusing whatever account is already logged
// into the Firebase CLI on this machine (`firebase login`), converting its
// cached OAuth refresh token into an Application Default Credentials file —
// the same technique `firebase functions:shell`/emulators use to give local
// code real project access. Requires the machine running these tests to
// have an authenticated `firebase login` session.
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

// Accounts are admin-created only now — the login page has no
// self-registration path (an email with no account shows an error instead).
// This mirrors createUser in functions/src/index.ts closely enough for e2e
// purposes, without needing an authenticated admin session to call the real
// callable.
export async function createPasswordlessAccount(email: string): Promise<string> {
  ensureInitialized();
  const user = await getAuth().createUser({ email });
  await getFirestore().doc(`users/${user.uid}`).set({ email }, { merge: true });
  return user.uid;
}
