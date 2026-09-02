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

// Every run-*-patrol-test.mjs / run-patient-flow-e2e.mjs's own cleanup()
// does a broad prefix sweep for accounts/hospitals/patients matching its
// own naming convention — deliberately not scoped to "this run's own
// state", so an interrupted run (killed process, a crash between
// --seed-only and --teardown) doesn't orphan its state forever (see each
// cleanup()'s own comment). But sibling e2e jobs run *concurrently* in the
// same GHA workflow (flutter-web-e2e and flutter-android-e2e-seed have no
// `needs` between them, and the three flutter-android-e2e-* run jobs
// downstream of seed run concurrently with each other too), so an
// unscoped sweep can delete a DIFFERENT,
// still-in-use run's state out from under it mid-test. Confirmed for
// real: the web job's own physician cleanup deleted the Android job's
// still-in-progress physician account ~2 minutes before that job ever got
// to check it, surfacing as a baffling "Account not activated" screen
// with no other explanation — the account genuinely no longer existed by
// the time it was needed.
//
// Every name/email this codebase generates already embeds its own
// creation timestamp (RUN_ID = Date.now(), a 13-digit epoch ms value) as
// a trailing token — reusing that (rather than adding a separate
// createdAt field to every seed write, and a Firestore query need for
// each) lets a sweep skip anything young enough to plausibly still be a
// sibling job's in-flight state, while still catching genuinely orphaned
// debris from crashed/interrupted past runs once they're safely old.
const MIN_SWEEP_AGE_MS = 20 * 60 * 1000; // 20 minutes — comfortably longer than any single e2e job takes.

export function isOldEnoughToSweep(text, referenceMs = Date.now()) {
  // Not a string at all (e.g. an encrypted `{ciphertext: ...}` field, like
  // an EMS-app-uploaded patient's `name` — see patient_upload_service.dart)
  // as much as a genuinely missing one: nothing to extract an age from
  // either way, so don't let it block a sweep decision that some OTHER,
  // analyzable field on the same document already made.
  if (typeof text !== 'string') return true;
  const match = text.match(/(\d{13})/);
  // No embedded timestamp at all shouldn't happen for anything this
  // codebase's own scripts create — sweep it rather than let a naming
  // mismatch quietly leave debris behind forever.
  if (!match) return true;
  return referenceMs - Number(match[1]) > MIN_SWEEP_AGE_MS;
}
