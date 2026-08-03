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
// nx-monorepo already has that set up.
//
// Usage: node scripts/run-physician-patrol-test.mjs
// Requires: flutter + patrol_cli on PATH (or edit scripts/lib/run-patrol.mjs
// to match your machine), a cached `firebase login` CLI session (or
// GOOGLE_APPLICATION_CREDENTIALS set, e.g. in CI).

import { FieldValue } from 'firebase-admin/firestore';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { findOrganizationId, initFirebaseAdmin } from './lib/firebase-admin-cli.mjs';
import { runPatrolTest } from './lib/run-patrol.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..', '..');
const PHYSICIAN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'physician');

const RUN_ID = Date.now();
const HOSPITAL_NAME = `Patrol Physician Test Hospital ${RUN_ID}`;
const PATIENT_NAME = `Patrol Physician Test Patient ${RUN_ID}`;

async function createSmokePhysicianAccount(db) {
  const organizationId = await findOrganizationId(db, 'test-org');
  const email = `smoke-physician-${RUN_ID}@amdash-e2e.test`;
  const password = 'SmokeTest123';
  const user = await getAuth().createUser({ email, password });
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
    location: { latitude: 43.6426, longitude: -79.3871, address: '' },
    organizationId,
    status: 'active',
    submittedAt: FieldValue.serverTimestamp(),
  });

  return { email, password, uid: user.uid, hospitalId: hospitalRef.id, patientId: patientRef.id };
}

async function cleanup(db, auth, account) {
  if (!account) return;
  await auth.deleteUser(account.uid).catch(() => {});
  await db.doc(`users/${account.uid}`).delete().catch(() => {});
  await db.doc(`hospitals/${account.hospitalId}`).delete().catch(() => {});
  await db.doc(`patients/${account.patientId}`).delete().catch(() => {});
  console.log('Cleanup: removed throwaway physician account, hospital, and patient.');
}

const credentialPath = initFirebaseAdmin('physicianpatrol');
const db = getFirestore();
const auth = getAuth();

let account;
let exitCode = 1;
try {
  account = await createSmokePhysicianAccount(db);
  console.log('Created throwaway physician account:', account.email);
  console.log('Seeded hospital:', HOSPITAL_NAME, '/ patient:', PATIENT_NAME);
  exitCode = await runPatrolTest({
    appDir: PHYSICIAN_APP_DIR,
    target: 'patrol_test/patient_flow_test.dart',
    dartDefines: {
      SMOKE_EMAIL: account.email,
      SMOKE_PASSWORD: account.password,
      SMOKE_HOSPITAL: HOSPITAL_NAME,
      SMOKE_PATIENT_NAME: PATIENT_NAME,
    },
  });
} finally {
  await cleanup(db, auth, account);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
