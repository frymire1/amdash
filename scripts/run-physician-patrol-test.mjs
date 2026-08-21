#!/usr/bin/env node
// Self-contained runner for the physician app's Patrol e2e test — same
// pattern as run-admin-patrol-test.mjs: create throwaway Firebase state
// (account, hospital, patient), run `patrol test`, always clean up
// regardless of pass/fail. Wired into .github/workflows/ci.yml's e2e job —
// not a local-only dev tool.
//
// Written in Node/JS rather than Dart for the same reason as
// run-admin-patrol-test.mjs: needs the Firebase *Admin* SDK to seed/tear
// down real Auth + Firestore state around the Dart-side Patrol test, and
// scripts/ already has that set up.
//
// Usage:
//   node scripts/run-physician-patrol-test.mjs
//     Default: seed, run `patrol test`, teardown, all in one process — used
//     by web-e2e (Chrome). PATROL_DEVICE=android|ios overrides the default
//     'chrome' device — 'android'/'ios' get resolved to the actual connected
//     emulator/simulator device id at run time (see
//     scripts/lib/run-patrol.mjs's resolveDeviceId).
//   node scripts/run-physician-patrol-test.mjs --seed-only [--account-json=<path>]
//     Seeds only, writes the seeded account/hospital/patient to
//     --account-json (default: an os.tmpdir() path) and exits 0 without
//     running patrol or tearing down. Used ahead of `patrol build` in the
//     Firebase Test Lab (android-e2e/ios-e2e) workflows, where the app is
//     built once with these values baked in as --dart-define flags rather
//     than run locally via `patrol test`.
//   node scripts/run-physician-patrol-test.mjs --teardown [--account-json=<path>]
//     Reads --account-json, tears the seeded state down, deletes the file,
//     and exits. Used after the `gcloud firebase test ... run` step in the
//     Test Lab workflows — a separate step from seeding, so it must be
//     invoked independently rather than via the try/finally below.
// Requires: flutter + patrol_cli on PATH (or edit scripts/lib/run-patrol.mjs
// to match your machine), a cached `firebase login` CLI session (or
// GOOGLE_APPLICATION_CREDENTIALS set, e.g. in CI).

import { FieldValue } from 'firebase-admin/firestore';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { findOrganizationId, initFirebaseAdmin } from './lib/firebase-admin-cli.mjs';
import { runPatrolTest } from './lib/run-patrol.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const PHYSICIAN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'physician');
const DEFAULT_ACCOUNT_JSON_PATH = path.join(os.tmpdir(), 'amdash-physician-smoke-account.json');

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

async function createSmokePhysicianAccount(db) {
  const organizationId = await findOrganizationId(db, 'test-org');
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

  // patient.location doesn't exist anymore (removed this session — GPS now
  // only ever lives in this subcollection, seeded atomically alongside the
  // patient doc by uploadPatientDocument in production). This seed script
  // predates that and was still writing the old field directly, which the
  // app silently ignores — PatientViewer's map gates on the live tracked
  // position (patients/{id}/location/current), not a static field, so the
  // map correctly never rendered. Confirmed via a real GHA failure
  // ("Found 0 widgets with type GoogleMap").
  await patientRef.collection('location').doc('current').set({
    patientId: patientRef.id,
    organizationId,
    active: true,
    latitude: 43.6426,
    longitude: -79.3871,
    updatedAt: FieldValue.serverTimestamp(),
  });

  return {
    email,
    password,
    uid: user.uid,
    hospitalId: hospitalRef.id,
    patientId: patientRef.id,
    hospitalName: HOSPITAL_NAME,
    patientName: PATIENT_NAME,
  };
}

async function cleanup(db, auth, account) {
  if (!account) return;
  await auth.deleteUser(account.uid).catch(() => {});
  await db.doc(`users/${account.uid}`).delete().catch(() => {});
  await db.doc(`hospitals/${account.hospitalId}`).delete().catch(() => {});
  await db.doc(`patients/${account.patientId}`).delete().catch(() => {});
  console.log('Cleanup: removed throwaway physician account, hospital, and patient.');
}

const { seedOnly, teardown, accountJsonPath } = parseArgs(process.argv.slice(2));

const credentialPath = initFirebaseAdmin('physicianpatrol');
const db = getFirestore();
const auth = getAuth();

if (teardown) {
  const account = JSON.parse(fs.readFileSync(accountJsonPath, 'utf8'));
  await cleanup(db, auth, account);
  fs.unlinkSync(accountJsonPath);
  if (credentialPath) fs.unlinkSync(credentialPath);
  console.log('Teardown complete.');
  process.exit(0);
}

let account;
let exitCode = 1;
try {
  account = await createSmokePhysicianAccount(db);
  console.log('Created throwaway physician account:', account.email);
  console.log('Seeded hospital:', HOSPITAL_NAME, '/ patient:', PATIENT_NAME);

  if (seedOnly) {
    fs.writeFileSync(accountJsonPath, JSON.stringify(account));
    console.log('Wrote seeded account to', accountJsonPath);
    exitCode = 0;
  } else {
    exitCode = await runPatrolTest({
      appDir: PHYSICIAN_APP_DIR,
      target: 'patrol_test/patient_flow_test.dart',
      dartDefines: {
        SMOKE_EMAIL: account.email,
        SMOKE_PASSWORD: account.password,
        SMOKE_HOSPITAL: HOSPITAL_NAME,
        SMOKE_PATIENT_NAME: PATIENT_NAME,
      },
      device: process.env.PATROL_DEVICE || 'chrome',
    });
  }
} finally {
  // --seed-only intentionally skips cleanup — teardown happens in a later,
  // separately-invoked `--teardown` run (see the Test Lab workflows), after
  // `patrol build` + `gcloud firebase test ... run` have both used this
  // seeded state.
  if (!seedOnly) await cleanup(db, auth, account);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

if (seedOnly) {
  console.log(exitCode === 0 ? '\n✅ Seed complete.' : '\n❌ Seed failed.');
} else {
  console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
}
process.exit(exitCode);
