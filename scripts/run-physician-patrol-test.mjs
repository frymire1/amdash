#!/usr/bin/env node
// Self-contained runner for the physician app's Patrol e2e test — same
// pattern as run-admin-patrol-test.mjs, except the *web* leg below signs
// into a persistent account rather than a fresh throwaway one, so it can
// merge patient_flow_test.dart's own wrong-app-rejection phase into the
// same session ahead of the real sign-in (that phase needs the CRUD
// account already MFA-enrolled *before* this run starts — nothing in a
// single continuous session can both enroll fresh and also resolve a
// prior scenario's own account-switch cleanly, see patient_flow_test.dart
// and ems_test.dart's own header comments). persistent-physician@
// amdash-e2e.test was created once (Admin SDK), had its workLocation
// field set once directly (also Admin SDK — a plain persistent string
// field, no UI needed, unlike MFA), and was MFA-enrolled once by hand,
// driving the real enrollment UI locally (no server-side shortcut exists
// for TOTP — see amdash_patrol_helpers' completeMfaEnrollment) — its TOTP
// secret is stored as the E2E_PHYSICIAN_TOTP_SECRET repo secret, read
// here and passed through to signInWithTotp. Never torn down between
// runs.
//
// The *Android* leg (--seed-only/--teardown, used by flutter-android-e2e)
// deliberately keeps its own fresh, throwaway account instead — NOT the
// persistent one, even though ems_test.dart's equivalent Android leg does
// share its persistent account. The difference: physician's own default
// patient-list filter defaults to profile.workLocation, a single mutable
// field on the account doc. The web leg above and the Android leg run in
// genuinely concurrent CI jobs (flutter-web-e2e/flutter-android-e2e, no
// `needs` between them) — sharing one account would mean each leg's own
// workLocation write could race the other's read, with no way to tell
// which wrote last. EMS has no equivalent shared single-value state (its
// own patient is always found by a uniquely-timestamped name, not a
// shared filter default), which is why *that* app's Android leg safely
// reuses its persistent account and this one doesn't. Confirmed as a real
// risk, not hypothetical, once patient_flow_test.dart started sharing an
// account across scenarios at all — see that file's own sign-in comment.
//
// Usage:
//   node scripts/run-physician-patrol-test.mjs
//     Default: seed a fresh hospital/patient, run `patrol test` against
//     Chrome using the persistent account, teardown that hospital/patient.
//     Used by web-e2e. PATROL_DEVICE=android|ios overrides the default
//     'chrome' device (not used by ci.yml — Android goes through the
//     --seed-only/--teardown path below instead, via `patrol build`).
//   node scripts/run-physician-patrol-test.mjs --seed-only [--account-json=<path>]
//     Creates a fresh throwaway account + hospital/patient, writes them to
//     --account-json, and exits 0 — no `patrol test` run. Used ahead of
//     `patrol build` in the Firebase Test Lab (flutter-android-e2e)
//     workflow.
//   node scripts/run-physician-patrol-test.mjs --teardown [--account-json=<path>]
//     Reads --account-json, deletes that run's own throwaway account +
//     hospital/patient, deletes the file, and exits. Used after the
//     `gcloud firebase test ... run` step in the Test Lab workflow.
// Requires: flutter + patrol_cli on PATH (or edit scripts/lib/run-patrol.mjs
// to match your machine), a cached `firebase login` CLI session (or
// GOOGLE_APPLICATION_CREDENTIALS set, e.g. in CI), and (default/web mode
// only) E2E_PHYSICIAN_PASSWORD/E2E_PHYSICIAN_TOTP_SECRET in the
// environment (repo secrets in CI).

import { FieldValue } from 'firebase-admin/firestore';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { findOrganizationId, initFirebaseAdmin, isOldEnoughToSweep } from './lib/firebase-admin-cli.mjs';
import { runPatrolTest } from './lib/run-patrol.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const PHYSICIAN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'physician');
const DEFAULT_ACCOUNT_JSON_PATH = path.join(os.tmpdir(), 'amdash-physician-smoke-account.json');

// Web leg only — see this file's own header comment for why Android
// doesn't use these.
const PHYSICIAN_EMAIL = 'persistent-physician@amdash-e2e.test';
const WRONG_APP_EMAIL = 'persistent-ems@amdash-e2e.test';
const PHYSICIAN_PASSWORD = process.env.E2E_PHYSICIAN_PASSWORD;
const PHYSICIAN_TOTP_SECRET = process.env.E2E_PHYSICIAN_TOTP_SECRET;

function parseArgs(argv) {
  const seedOnly = argv.includes('--seed-only');
  const teardown = argv.includes('--teardown');
  if (seedOnly && teardown) throw new Error('--seed-only and --teardown are mutually exclusive.');
  const accountJsonArg = argv.find((arg) => arg.startsWith('--account-json='));
  const accountJsonPath = accountJsonArg ? accountJsonArg.slice('--account-json='.length) : DEFAULT_ACCOUNT_JSON_PATH;
  return { seedOnly, teardown, accountJsonPath };
}

const RUN_ID = Date.now();
const HOSPITAL_NAME = `Patrol Physician Test Hospital ${RUN_ID}`;
const PATIENT_NAME = `Patrol Physician Test Patient ${RUN_ID}`;

async function seedHospitalAndPatient(db, organizationId) {
  // Downtown Toronto — arbitrary but real coordinates so the map/marker in
  // the patient viewer has something to render.
  const hospitalRef = await db.collection('hospitals').add({
    name: HOSPITAL_NAME,
    address: '100 Queen St W, Toronto, ON',
    latitude: 43.6534,
    longitude: -79.3839,
    organizationId,
  });

  const patientRef = await db.collection('patients').add({
    name: PATIENT_NAME,
    gender: 'Unknown',
    age: 'Unknown',
    healthcareNumber: 'Unknown',
    destination: HOSPITAL_NAME,
    vitals: { heartRate: 82, bloodPressure: '120/80', oxygen: 98, temperature: 37 },
    organizationId,
    status: 'active',
    submittedAt: FieldValue.serverTimestamp(),
  });

  await patientRef.collection('location').doc('current').set({
    patientId: patientRef.id,
    organizationId,
    active: true,
    latitude: 43.6426,
    longitude: -79.3871,
    updatedAt: FieldValue.serverTimestamp(),
  });

  return { hospitalId: hospitalRef.id, patientId: patientRef.id, hospitalName: HOSPITAL_NAME, patientName: PATIENT_NAME };
}

// Android leg only (--seed-only/--teardown) — see this file's own header
// comment for why this platform still gets its own fresh, throwaway
// account rather than the persistent one the web leg below uses.
async function createThrowawayPhysicianAccount(db, organizationId) {
  const email = `smoke-physician-${RUN_ID}@amdash-e2e.test`;
  const password = 'SmokeTest123';
  // emailVerified: true — required for mandatory MFA's /mfa-setup screen to
  // skip straight to TOTP enrollment (see run-admin-patrol-test.mjs's fuller
  // comment on this same line).
  const user = await getAuth().createUser({ email, password, emailVerified: true });
  await db.doc(`users/${user.uid}`).set(
    { email, role: ['physician'], organizationId, firstName: 'Smoke', lastName: 'Physician' },
    { merge: true },
  );
  return { email, password, uid: user.uid };
}

async function cleanupHospitalAndPatient(db, organizationId, seeded) {
  if (seeded) {
    await db.doc(`hospitals/${seeded.hospitalId}`).delete().catch(() => {});
    await db.doc(`patients/${seeded.patientId}`).delete().catch(() => {});
  }

  // Age-guarded broad sweep for anything an interrupted run left behind —
  // see isOldEnoughToSweep's own comment for why this exists alongside
  // the specific deletes above.
  const hospSnap = await db
    .collection('hospitals')
    .where('organizationId', '==', organizationId)
    .where('name', '>=', 'Patrol Physician Test Hospital')
    .where('name', '<', 'Patrol Physician Test Hospitc')
    .get();
  let deletedHospitals = 0;
  for (const doc of hospSnap.docs) {
    if (isOldEnoughToSweep(doc.data().name)) {
      await doc.ref.delete();
      deletedHospitals++;
    }
  }

  const patientSnap = await db
    .collection('patients')
    .where('organizationId', '==', organizationId)
    .where('name', '>=', 'Patrol Physician Test Patient')
    .where('name', '<', 'Patrol Physician Test Patiend')
    .get();
  let deletedPatients = 0;
  for (const doc of patientSnap.docs) {
    if (isOldEnoughToSweep(doc.data().name)) {
      await doc.ref.delete();
      deletedPatients++;
    }
  }

  console.log(`Cleanup: removed ${deletedHospitals} hospital(s), ${deletedPatients} patient(s).`);
}

// Android leg only — see createThrowawayPhysicianAccount's own comment.
async function cleanupThrowawayAccount(db, auth, uid) {
  if (uid) {
    await auth.deleteUser(uid).catch(() => {});
    await db.doc(`users/${uid}`).delete().catch(() => {});
  }
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (user.email?.startsWith('smoke-physician-') && user.uid !== uid && isOldEnoughToSweep(user.email)) {
        await auth.deleteUser(user.uid).catch(() => {});
        await db.doc(`users/${user.uid}`).delete().catch(() => {});
        deletedUsers++;
      }
    }
    pageToken = page.pageToken;
  } while (pageToken);
  console.log(`Cleanup: removed 1 throwaway physician account, ${deletedUsers} other leftover account(s).`);
}

const { seedOnly, teardown, accountJsonPath } = parseArgs(process.argv.slice(2));
const credentialPath = initFirebaseAdmin('physicianpatrol');
const db = getFirestore();
const auth = getAuth();

if (teardown) {
  const seeded = JSON.parse(fs.readFileSync(accountJsonPath, 'utf8'));
  const organizationId = await findOrganizationId(db, 'test-org');
  await cleanupHospitalAndPatient(db, organizationId, seeded);
  await cleanupThrowawayAccount(db, auth, seeded.uid);
  fs.unlinkSync(accountJsonPath);
  if (credentialPath) fs.unlinkSync(credentialPath);
  console.log('Teardown complete.');
  process.exit(0);
}

if (seedOnly) {
  // Android leg — fresh throwaway account, same as every other app's own
  // Android build. See this file's own header comment for why.
  const organizationId = await findOrganizationId(db, 'test-org');
  const account = await createThrowawayPhysicianAccount(db, organizationId);
  const seededPlace = await seedHospitalAndPatient(db, organizationId);
  console.log('Created throwaway physician account:', account.email);
  console.log('Seeded hospital:', HOSPITAL_NAME, '/ patient:', PATIENT_NAME);
  fs.writeFileSync(accountJsonPath, JSON.stringify({ ...account, ...seededPlace }));
  console.log('Wrote seeded account to', accountJsonPath);
  if (credentialPath) fs.unlinkSync(credentialPath);
  console.log('\n✅ Seed complete.');
  process.exit(0);
}

// Default — web leg, the persistent account.
if (!PHYSICIAN_PASSWORD || !PHYSICIAN_TOTP_SECRET) {
  console.error('E2E_PHYSICIAN_PASSWORD and E2E_PHYSICIAN_TOTP_SECRET must both be set in the environment.');
  process.exit(1);
}

let seeded;
let exitCode = 1;
try {
  const organizationId = await findOrganizationId(db, 'test-org');
  seeded = await seedHospitalAndPatient(db, organizationId);
  console.log('Seeded hospital:', HOSPITAL_NAME, '/ patient:', PATIENT_NAME);

  exitCode = await runPatrolTest({
    appDir: PHYSICIAN_APP_DIR,
    target: 'patrol_test/patient_flow_test.dart',
    dartDefines: {
      SMOKE_EMAIL: PHYSICIAN_EMAIL,
      SMOKE_PASSWORD: PHYSICIAN_PASSWORD,
      SMOKE_TOTP_SECRET: PHYSICIAN_TOTP_SECRET,
      SMOKE_HOSPITAL: HOSPITAL_NAME,
      SMOKE_PATIENT_NAME: PATIENT_NAME,
      WRONG_APP_EMAIL: WRONG_APP_EMAIL,
    },
    device: 'chrome',
  });
} finally {
  const organizationId = await findOrganizationId(db, 'test-org');
  await cleanupHospitalAndPatient(db, organizationId, seeded);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
