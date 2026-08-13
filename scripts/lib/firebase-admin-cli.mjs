// Shared by the self-contained Patrol test runners (run-*-patrol-test.mjs)
// — permanent infrastructure, not a one-off script. Node/JS rather than
// Dart because it wraps the Firebase *Admin* SDK, which the Patrol tests
// themselves need for elevated, server-side setup/teardown (creating and
// deleting real Auth users, bypassing Firestore rules) that a normal
// signed-in Dart client app can't do.
//
// Locally, builds Application Default Credentials from the Firebase CLI's
// own cached OAuth session (`firebase login`) rather than requiring a
// separate service account key on every developer's machine.
// client_id/client_secret below are the Firebase CLI's own public OAuth
// client, not a project secret.
//
// In CI, GOOGLE_APPLICATION_CREDENTIALS is already set (see
// .github/workflows/ci.yml's "Authenticate to Firebase" step, which writes
// the FIREBASE_SERVICE_ACCOUNT_KEY repo secret to a file) and there's no
// `firebase login` session to read — use it as-is instead.
import { initializeApp } from 'firebase-admin/app';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export function initFirebaseAdmin(tag) {
  if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    initializeApp({ projectId: 'amdash-dev' });
    return null;
  }

  const firebaseToolsConfigPath = path.join(os.homedir(), '.config/configstore/firebase-tools.json');
  const { tokens } = JSON.parse(fs.readFileSync(firebaseToolsConfigPath, 'utf8'));
  const credential = {
    client_id: '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com',
    client_secret: 'j9iVZfS8kkCEFUPaAeJV0sAi',
    refresh_token: tokens.refresh_token,
    type: 'authorized_user',
  };
  const credentialPath = path.join(os.tmpdir(), `amdash-${tag}-adc-${process.pid}.json`);
  fs.writeFileSync(credentialPath, JSON.stringify(credential));
  process.env['GOOGLE_APPLICATION_CREDENTIALS'] = credentialPath;
  initializeApp({ projectId: 'amdash-dev' });
  return credentialPath;
}

export async function findOrganizationId(db, name) {
  const orgSnap = await db.collection('organizations').where('name', '==', name).get();
  const organizationId = orgSnap.docs[0]?.id;
  if (!organizationId) throw new Error(`${name} not found — seed it before running this script.`);
  return organizationId;
}
