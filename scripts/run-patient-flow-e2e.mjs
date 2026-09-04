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
import { findOrganizationId, initFirebaseAdmin, isOldEnoughToSweep } from './lib/firebase-admin-cli.mjs';
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
  //
  // etaAlertThresholdsMinutes pre-seeded the same way, rather than driven
  // through Settings' own checkbox + Enable button in the test itself —
  // Enable needs a real FCM permission + token round trip, which Patrol's
  // bundled Playwright Chromium cannot complete for real (confirmed:
  // Chrome's own "AbortError: Registration failed - permission denied" on
  // service-worker registration, consistent with a known Playwright/
  // Chromium limitation around push registration — see
  // incoming_patient_test.dart's own comment for the full story). What
  // this test verifies instead is the *read* half — that this real,
  // pre-seeded Firestore value correctly reaches and checks the right box
  // — via a genuine cross-process round trip; the write half (Enable
  // persisting a fresh selection) has full widget-test coverage instead
  // (user_settings_screen_test.dart), with PatientAlertService mocked out
  // so it doesn't depend on real browser push-registration support at all.
  await db.doc(`users/${physicianUser.uid}`).set(
    {
      email: physicianEmail,
      role: ['physician'],
      organizationId,
      firstName: 'Smoke',
      lastName: 'Physician',
      workLocation: HOSPITAL_NAME,
      etaAlertThresholdsMinutes: [30],
    },
    { merge: true },
  );

  return {
    hospitalId: hospitalRef.id,
    ems: { email: emsEmail, password: emsPassword, uid: emsUser.uid },
    physician: { email: physicianEmail, password: physicianPassword, uid: physicianUser.uid },
  };
}

// Verifies the real backend detection pipeline — functions/src/ems.ts's
// checkProximityAlertThresholds — actually fired for this live-tracked
// patient. The checkbox/preference side is verified separately, inside
// incoming_patient_test.dart itself (a real Firestore read confirming the
// pre-seeded etaAlertThresholdsMinutes correctly checks the right box —
// see seed()'s own comment above for why this doesn't go through the
// real Enable button). This check isn't tied to physician's own test
// timing at all: it's driven entirely by EMS's own location-publish ticks
// during *its* test run (a Cloud Function trigger, not something
// physician's separate process could influence either way), and the
// seeded GPS-fix/hospital pair is close enough that the 30-minute
// threshold (the largest one that exists — see ems.ts's
// PROXIMITY_THRESHOLDS_MINUTES) is essentially guaranteed to have already
// been crossed by the time this runs. Polls briefly regardless, purely as
// a safety margin against Cloud Functions cold-start latency, not because
// anything is expected to still be in-flight.
async function verifyEtaAlertThreshold(db) {
  const patientSnap = await db.collection('patients').where('destination', '==', HOSPITAL_NAME).limit(1).get();
  if (patientSnap.empty) {
    throw new Error(`No patient found with destination "${HOSPITAL_NAME}" to check notifiedThresholds on.`);
  }
  const locationRef = patientSnap.docs[0].ref.collection('location').doc('current');

  const deadline = Date.now() + 30_000;
  let notifiedThresholds = [];
  while (Date.now() < deadline) {
    const locationSnap = await locationRef.get();
    notifiedThresholds = locationSnap.data()?.notifiedThresholds ?? [];
    if (notifiedThresholds.includes(30)) {
      console.log('✅ Confirmed the real onEmsLocationEvent proximity-check pipeline recorded the 30-minute crossing.');
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 3_000));
  }
  throw new Error(
    `Expected patients/${patientSnap.docs[0].id}/location/current.notifiedThresholds to contain 30, got ${JSON.stringify(notifiedThresholds)}.`,
  );
}

async function cleanup(db, auth, seeded) {
  // Specific-reference deletes first, unconditional regardless of age —
  // this run's own account/hospital/patient just finished being used, so
  // there's never a reason to wait on them (unlike the broad sweep below,
  // scoped to catching debris from OTHER, possibly-still-running jobs).
  // Missing until this fix: cleanup() used to rely *entirely* on the
  // broad sweep below to find its own patient (no seed script writes it
  // directly — it's created through the EMS app's own UI, so there was
  // never an id to delete by), which meant adding the age guard to that
  // sweep broke this specific run's own timely cleanup — confirmed for
  // real: two "Patrol Flow Test Patient" leftovers with the same edited
  // heart rate collided in a very next run's own "found 2 widgets"
  // failure. `destination` is known up front (HOSPITAL_NAME) and unique
  // to this run by construction, so an *exact* match (not the broad
  // sweep's prefix range) finds it precisely, without needing to guess
  // at its Firestore doc id.
  if (seeded) {
    await auth.deleteUser(seeded.ems.uid).catch(() => {});
    await db.doc(`users/${seeded.ems.uid}`).delete().catch(() => {});
    await auth.deleteUser(seeded.physician.uid).catch(() => {});
    await db.doc(`users/${seeded.physician.uid}`).delete().catch(() => {});
    await db.doc(`hospitals/${seeded.hospitalId}`).delete().catch(() => {});
    const ownPatientSnap = await db.collection('patients').where('destination', '==', HOSPITAL_NAME).get();
    for (const doc of ownPatientSnap.docs) await db.recursiveDelete(doc.ref);
  }

  // Age-guarded (isOldEnoughToSweep) — a broad sweep with no age check can
  // delete a concurrently-running sibling run's still-in-use account/
  // hospital/patient (e.g. two overlapping pushes both triggering this
  // same script) — see that function's own comment for the real GHA
  // failure this was confirmed against. This run's own state is already
  // gone via the specific deletes above; this is purely a safety net for
  // orphaned debris from other, past runs.
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (
        user.email &&
        (user.email.startsWith('smoke-ems-flow-') || user.email.startsWith('smoke-physician-flow-')) &&
        isOldEnoughToSweep(user.email)
      ) {
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
  let deletedHospitals = 0;
  for (const doc of hospSnap.docs) {
    if (isOldEnoughToSweep(doc.data().name)) {
      await doc.ref.delete();
      deletedHospitals++;
    }
  }

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
  let deletedPatients = 0;
  for (const doc of patientSnap.docs) {
    if (isOldEnoughToSweep(doc.data().destination)) {
      await db.recursiveDelete(doc.ref);
      deletedPatients++;
    }
  }

  console.log(
    `Cleanup: removed ${deletedUsers} throwaway user(s), ${deletedHospitals} leftover hospital(s), ` +
      `${deletedPatients} leftover patient(s).`,
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

    if (exitCode === 0) {
      try {
        await verifyEtaAlertThreshold(db);
      } catch (error) {
        console.error(error.message);
        exitCode = 1;
      }
    } else {
      console.log('\n❌ Physician verification failed — skipping the proximity-alert checks (nothing meaningful to verify).');
    }
  }
} finally {
  await cleanup(db, auth, seeded);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
