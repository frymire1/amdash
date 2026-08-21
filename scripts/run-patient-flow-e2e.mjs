#!/usr/bin/env node
// Cross-app e2e: an EMS account uploads a real patient (through the EMS
// app's own UI, live-tracking enabled, GPS mocked via Playwright's
// geolocation override — see runPatrolTest's webGeolocation param) and a
// physician account in the same org then signs in and confirms that exact
// patient shows up with a live map centered on the mocked coordinates.
// Unlike run-admin/physician/ems-patrol-test.mjs (each scoped to one app
// verifying its own UI against Firebase Admin SDK-seeded state), this one
// verifies the real cross-app path: EMS's upload is genuinely what makes
// the patient visible to physician, not a seed script standing in for it.
//
// Patrol can't drive two apps in one process (each `patrol test` is a
// separate compiled Flutter binary/process) — this runs two *sequential*
// Patrol tests instead, coordinated the same way the existing scripts
// already coordinate EMS's seed data with physician's dart-defines: a
// shared, deterministic patient/hospital name generated here up front,
// not any live signal between the two runs. The physician run only
// starts if the EMS run actually passed — if EMS failed, the patient was
// never uploaded, so running physician's check anyway would just be a
// second, confusing failure for the same root cause.
//
// Usage: node scripts/run-patient-flow-e2e.mjs
// Requires: flutter + patrol_cli on PATH (or edit FLUTTER_BIN/PATROL_BIN in
// scripts/lib/run-patrol.mjs to match your machine), a cached `firebase
// login` CLI session (or GOOGLE_APPLICATION_CREDENTIALS set, e.g. in CI).

import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { findOrganizationId, initFirebaseAdmin } from './lib/firebase-admin-cli.mjs';
import { runPatrolTest } from './lib/run-patrol.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const EMS_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'ems');
const PHYSICIAN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'physician');

const RUN_ID = Date.now();
const HOSPITAL_NAME = `Patrol Flow Test Hospital ${RUN_ID}`;
const PATIENT_NAME = `Patrol Flow Test Patient ${RUN_ID}`;

// Real, arbitrary Toronto coordinates (same convention as the other seed
// scripts) — GPS_LATITUDE/GPS_LONGITUDE are what gets mocked as the EMS
// browser's location, and what the physician test expects the map/"Live
// position" text to reflect exactly, since a mock has no GPS noise to
// account for. A few km from the hospital itself so a real, sensible
// Directions API route exists between them.
const GPS_LATITUDE = 43.6629;
const GPS_LONGITUDE = -79.3957;

async function seed(db) {
  const organizationId = await findOrganizationId(db, 'test-org');

  const hospitalRef = await db.collection('hospitals').add({
    name: HOSPITAL_NAME,
    address: '100 Queen St W, Toronto, ON',
    latitude: 43.6534,
    longitude: -79.3839,
    organizationId,
  });

  const emsEmail = `smoke-ems-flow-${RUN_ID}@amdash-e2e.test`;
  const emsPassword = 'SmokeTest123';
  const emsUser = await getAuth().createUser({ email: emsEmail, password: emsPassword, emailVerified: true });
  await db
    .doc(`users/${emsUser.uid}`)
    .set({ email: emsEmail, role: ['ems'], organizationId, firstName: 'Smoke', lastName: 'Ems' }, { merge: true });

  const physicianEmail = `smoke-physician-flow-${RUN_ID}@amdash-e2e.test`;
  const physicianPassword = 'SmokeTest123';
  const physicianUser = await getAuth().createUser({
    email: physicianEmail,
    password: physicianPassword,
    emailVerified: true,
  });
  // workLocation set directly here, rather than driven through the
  // /work-location screen in the test itself (see patient_flow_test.dart
  // for that flow) — this test is about the EMS-to-physician handoff, not
  // work-location setup, which is already covered elsewhere. Has to match
  // HOSPITAL_NAME exactly: PatientList's destination filter defaults to
  // the physician's own workLocation, and a patient whose destination
  // doesn't match it is filtered out of the default view entirely (a real
  // one found live during this session's own manual testing, not a
  // hypothetical).
  await db.doc(`users/${physicianUser.uid}`).set(
    {
      email: physicianEmail,
      role: ['physician'],
      organizationId,
      firstName: 'Smoke',
      lastName: 'Physician',
      workLocation: HOSPITAL_NAME,
    },
    { merge: true },
  );

  return {
    hospitalId: hospitalRef.id,
    ems: { email: emsEmail, password: emsPassword, uid: emsUser.uid },
    physician: { email: physicianEmail, password: physicianPassword, uid: physicianUser.uid },
  };
}

async function cleanup(db, auth) {
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (user.email && (user.email.startsWith('smoke-ems-flow-') || user.email.startsWith('smoke-physician-flow-'))) {
        await auth.deleteUser(user.uid);
        await db.doc(`users/${user.uid}`).delete().catch(() => {});
        deletedUsers++;
      }
    }
    pageToken = page.pageToken;
  } while (pageToken);

  const hospSnap = await db
    .collection('hospitals')
    .where('name', '>=', 'Patrol Flow Test Hospital')
    .where('name', '<', 'Patrol Flow Test Hospitc')
    .get();
  for (const doc of hospSnap.docs) await doc.ref.delete();

  // The patient itself (created by the EMS app, not this script) — matched
  // by `destination`, NOT `name`. `name` is encrypted client-side by the
  // real upload flow this patient goes through (see
  // patient_upload_service.dart/encryptPatientFields) — a plaintext range
  // query against it can never match anything, which is exactly what let
  // every single run's patient silently pile up in test-org instead of
  // ever being deleted (confirmed for real: found many leftover "Patrol
  // Flow Test Patient" documents going back hours once this was noticed).
  // `destination` holds the plaintext hospital name (not PII, needed for
  // physician's own destination filter) and this test always sets it to
  // HOSPITAL_NAME, so it's a safe, reliably-queryable stand-in.
  // recursiveDelete so its location subcollection goes with it, matching
  // onPatientDeleted's own cleanup in production (see functions/src/ems.ts).
  const patientSnap = await db
    .collection('patients')
    .where('destination', '>=', 'Patrol Flow Test Hospital')
    .where('destination', '<', 'Patrol Flow Test Hospitc')
    .get();
  for (const doc of patientSnap.docs) await db.recursiveDelete(doc.ref);

  console.log(
    `Cleanup: removed ${deletedUsers} throwaway user(s), ${hospSnap.size} leftover hospital(s), ` +
      `${patientSnap.size} leftover patient(s).`,
  );
}

const credentialPath = initFirebaseAdmin('patientflow');
const db = getFirestore();
const auth = getAuth();

let seeded;
let exitCode = 1;
try {
  seeded = await seed(db);
  console.log('Created throwaway ems account:', seeded.ems.email);
  console.log('Created throwaway physician account:', seeded.physician.email);
  console.log('Seeded hospital:', HOSPITAL_NAME);

  const emsExitCode = await runPatrolTest({
    appDir: EMS_APP_DIR,
    target: 'patrol_test/patient_upload_flow_test.dart',
    dartDefines: {
      SMOKE_EMAIL: seeded.ems.email,
      SMOKE_PASSWORD: seeded.ems.password,
      SMOKE_HOSPITAL: HOSPITAL_NAME,
      SMOKE_PATIENT_NAME: PATIENT_NAME,
    },
    webGeolocation: { latitude: GPS_LATITUDE, longitude: GPS_LONGITUDE },
    webPermissions: ['geolocation'],
  });

  if (emsExitCode !== 0) {
    console.log('\n❌ EMS upload step failed — skipping the physician verification step (nothing was uploaded).');
    exitCode = emsExitCode;
  } else {
    exitCode = await runPatrolTest({
      appDir: PHYSICIAN_APP_DIR,
      target: 'patrol_test/incoming_patient_test.dart',
      dartDefines: {
        SMOKE_EMAIL: seeded.physician.email,
        SMOKE_PASSWORD: seeded.physician.password,
        SMOKE_PATIENT_NAME: PATIENT_NAME,
        SMOKE_LATITUDE: String(GPS_LATITUDE),
        SMOKE_LONGITUDE: String(GPS_LONGITUDE),
      },
    });
  }
} finally {
  await cleanup(db, auth);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
