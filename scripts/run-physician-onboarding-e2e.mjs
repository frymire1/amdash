#!/usr/bin/env node
// Cross-app e2e: an admin account creates a new physician user through
// the admin app's own real UI (no password, no work-location, nothing
// pre-seeded — see admin/patrol_test/create_user_test.dart), and that
// exact account then completes its own real first-ever sign-in (set a
// password, enroll MFA, set a work location) through the physician app's
// own UI (see physician/patrol_test/first_login_test.dart). Unlike every
// other run-*-patrol-test.mjs (each scoped to one app verifying its own
// UI against Admin-SDK-seeded state, including an already-set password),
// this one verifies the real onboarding path every actual new physician
// goes through — admin's createUser call is what makes the account exist
// and passwordless, not a seed script standing in for it.
//
// A third leg then covers the matching failure state: an admin-created
// *ems*-role account attempting to sign into the physician app instead —
// rejected right after email (checkAccountStatus's own roleAllowed
// field, see functions/src/auth.ts), before a password is ever relevant,
// landing on AccessDeniedScreen, never MainViewScreen. See
// physician/patrol_test/wrong_app_login_test.dart.
//
// All three legs run on Chrome (unlike run-ems-onboarding-e2e.mjs's
// sibling, which needs a real Android device for its EMS legs) — mirrors
// run-patient-flow-e2e.mjs's own two-sequential-Patrol-runs shape,
// extended to three, just for account onboarding instead of a patient
// handoff.
//
// Usage: node scripts/run-physician-onboarding-e2e.mjs
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
const ADMIN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'admin');
const PHYSICIAN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'physician');

const RUN_ID = Date.now();
const HOSPITAL_NAME = `Patrol Onboarding Test Hospital ${RUN_ID}`;
const NEW_USER_EMAIL = `smoke-physician-onboarding-${RUN_ID}@amdash-e2e.test`;
// The wrong-app leg's account — deliberately a *different* prefix
// (smoke-ems-wrongapp-, not smoke-physician-onboarding-) so its own sweep
// in cleanup() below can't accidentally collide with a sibling
// run-ems-onboarding-e2e.mjs job's own smoke-ems-onboarding- accounts.
const WRONG_APP_USER_EMAIL = `smoke-ems-wrongapp-${RUN_ID}@amdash-e2e.test`;
// Must satisfy passwordMeetsComplexityRequirements (functions/src/auth.ts)
// — 8+ chars, an uppercase letter, a number, a special character — same as
// every other onboarding password this suite generates.
const NEW_USER_PASSWORD = 'OnboardTest1!';

async function seed(db) {
  const organizationId = await findOrganizationId(db, 'test-org');

  const hospitalRef = await db.collection('hospitals').add({
    name: HOSPITAL_NAME,
    address: '100 Queen St W, Toronto, ON',
    latitude: 43.6534,
    longitude: -79.3839,
    organizationId,
  });

  // Two separate admin accounts — mirrors run-admin-patrol-test.mjs's own
  // createSmokeAdminAccount, just twice. Genuinely two, not one reused
  // for both create_user_test.dart legs: completeMfaEnrollment
  // (amdash_patrol_helpers) hard-assumes a never-enrolled account and
  // goes straight for the enrollment screen's own secret — reusing the
  // same admin for a second sign-in, after its MFA is already enrolled
  // from the first, skips that screen entirely and the helper throws
  // "Bad state: No element" instead (confirmed for real: exactly this,
  // on a real CI run, before this fix). Neither the physician account nor
  // the wrong-app ems account is seeded here directly — both are real
  // outputs of the admin app's own createUser flow, not something this
  // script writes to Firestore/Auth itself.
  async function createAdmin(suffix) {
    const email = `smoke-admin-onboarding-${suffix}-${RUN_ID}@amdash-e2e.test`;
    const password = 'SmokeTest123';
    const user = await getAuth().createUser({ email, password, emailVerified: true });
    await db.doc(`users/${user.uid}`).set(
      { email, role: ['admin'], organizationId, firstName: 'Smoke', lastName: 'Admin' },
      { merge: true },
    );
    return { email, password, uid: user.uid };
  }
  const admin = await createAdmin('main');
  const wrongAppAdmin = await createAdmin('wrongapp');

  return { hospitalId: hospitalRef.id, admin, wrongAppAdmin };
}

async function cleanup(db, auth, seeded) {
  if (seeded) {
    await auth.deleteUser(seeded.admin.uid).catch(() => {});
    await db.doc(`users/${seeded.admin.uid}`).delete().catch(() => {});
    await auth.deleteUser(seeded.wrongAppAdmin.uid).catch(() => {});
    await db.doc(`users/${seeded.wrongAppAdmin.uid}`).delete().catch(() => {});
    await db.doc(`hospitals/${seeded.hospitalId}`).delete().catch(() => {});
    // Neither the new physician account nor the wrong-app ems account was
    // ever created by this script (see seed()'s own comment) — look them
    // up by their known, deterministic emails instead of ids this script
    // never had.
    for (const email of [NEW_USER_EMAIL, WRONG_APP_USER_EMAIL]) {
      const newUser = await auth.getUserByEmail(email).catch(() => null);
      if (newUser) {
        await auth.deleteUser(newUser.uid).catch(() => {});
        await db.doc(`users/${newUser.uid}`).delete().catch(() => {});
      }
    }
  }

  // Age-guarded broad sweep for anything an interrupted run left behind —
  // see isOldEnoughToSweep's own comment for why this exists alongside
  // the specific deletes above.
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (
        user.email &&
        (user.email.startsWith('smoke-admin-onboarding-') ||
          user.email.startsWith('smoke-physician-onboarding-') ||
          user.email.startsWith('smoke-ems-wrongapp-')) &&
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
    .where('name', '>=', 'Patrol Onboarding Test Hospital')
    .where('name', '<', 'Patrol Onboarding Test Hospitc')
    .get();
  let deletedHospitals = 0;
  for (const doc of hospSnap.docs) {
    if (isOldEnoughToSweep(doc.data().name)) {
      await doc.ref.delete();
      deletedHospitals++;
    }
  }

  console.log(`Cleanup: removed ${deletedUsers} throwaway user(s), ${deletedHospitals} leftover hospital(s).`);
}

const credentialPath = initFirebaseAdmin('physicianonboarding');
const db = getFirestore();
const auth = getAuth();

let seeded;
let exitCode = 1;
try {
  seeded = await seed(db);
  console.log('Created throwaway admin account:', seeded.admin.email);
  console.log('Created throwaway wrong-app-leg admin account:', seeded.wrongAppAdmin.email);
  console.log('Seeded hospital:', HOSPITAL_NAME);
  console.log('New physician account (created by the test itself):', NEW_USER_EMAIL);
  console.log('Wrong-app ems account (created by the test itself):', WRONG_APP_USER_EMAIL);

  const createPhysicianExitCode = await runPatrolTest({
    appDir: ADMIN_APP_DIR,
    target: 'patrol_test/create_user_test.dart',
    dartDefines: {
      SMOKE_EMAIL: seeded.admin.email,
      SMOKE_PASSWORD: seeded.admin.password,
      SMOKE_NEW_USER_EMAIL: NEW_USER_EMAIL,
      SMOKE_NEW_USER_ROLE: 'physician',
    },
  });

  if (createPhysicianExitCode !== 0) {
    console.log('\n❌ Admin create-user step failed — skipping the physician first-login step (account was never created).');
    exitCode = createPhysicianExitCode;
  } else {
    exitCode = await runPatrolTest({
      appDir: PHYSICIAN_APP_DIR,
      target: 'patrol_test/first_login_test.dart',
      dartDefines: {
        SMOKE_EMAIL: NEW_USER_EMAIL,
        SMOKE_NEW_PASSWORD: NEW_USER_PASSWORD,
        SMOKE_HOSPITAL: HOSPITAL_NAME,
      },
    });
  }

  // Third leg: the failure state. Runs regardless of how the two above
  // went — an independent account/scenario, no reason to skip it just
  // because the happy-path legs had trouble.
  const createWrongAppExitCode = await runPatrolTest({
    appDir: ADMIN_APP_DIR,
    target: 'patrol_test/create_user_test.dart',
    dartDefines: {
      SMOKE_EMAIL: seeded.wrongAppAdmin.email,
      SMOKE_PASSWORD: seeded.wrongAppAdmin.password,
      SMOKE_NEW_USER_EMAIL: WRONG_APP_USER_EMAIL,
      SMOKE_NEW_USER_ROLE: 'ems',
    },
  });

  let wrongAppExitCode = createWrongAppExitCode;
  if (createWrongAppExitCode === 0) {
    wrongAppExitCode = await runPatrolTest({
      appDir: PHYSICIAN_APP_DIR,
      target: 'patrol_test/wrong_app_login_test.dart',
      // No SMOKE_NEW_PASSWORD — wrong_app_login_test.dart is rejected
      // right after email, before a password is ever relevant (see its
      // own header comment).
      dartDefines: {SMOKE_EMAIL: WRONG_APP_USER_EMAIL},
    });
  } else {
    console.log('\n❌ Admin create-user step failed — skipping the wrong-app login step (account was never created).');
  }

  // Both onboarding and wrong-app legs have to pass for this script to
  // report success — a real regression in either is a real regression,
  // not something the other leg's result should be allowed to mask.
  if (exitCode === 0 && wrongAppExitCode !== 0) exitCode = wrongAppExitCode;
} finally {
  await cleanup(db, auth, seeded);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
