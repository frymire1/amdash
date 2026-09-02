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
// The matching failure-state leg (an admin-created *ems*-role account
// attempting to sign into the physician app instead) used to live here
// too, then briefly got merged into first_login_test.dart's own patrolTest
// block — reverted for real: the transition from "real onboarding, ends
// signed in" to "wrong-app, needs a clean LoginScreen" requires signing
// out, and AuthService.signOut() (amdash_core) deliberately calls
// FirebaseFirestore.terminate() + a full page reload on web (a documented
// fix for a real prior bug, not something to work around) — any reload
// mid-`patrolTest` kills the currently-running test outright, the same
// way Patrol's own reload *between* separate patrolTest blocks does (see
// run-physician-app-redirect-e2e.mjs's own header comment for that
// finding). No ordering avoids it: whichever scenario runs second still
// needs a clean LoginScreen, and the only in-app way there is a sign-out
// button that reloads. See run-physician-app-redirect-e2e.mjs, which now
// owns that scenario entirely, self-contained and Chrome-only, as its own
// parallel CI job instead.
//
// Runs on Chrome (unlike run-ems-onboarding-e2e.mjs's sibling, which needs
// a real Android device for its EMS-side equivalent).
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

  // Mirrors run-admin-patrol-test.mjs's own createSmokeAdminAccount. The
  // new physician account itself is never seeded here directly — it's a
  // real output of the admin app's own createUser flow, not something
  // this script writes to Firestore/Auth itself.
  const email = `smoke-admin-onboarding-${RUN_ID}@amdash-e2e.test`;
  const password = 'SmokeTest123';
  const user = await getAuth().createUser({ email, password, emailVerified: true });
  await db.doc(`users/${user.uid}`).set(
    { email, role: ['admin'], organizationId, firstName: 'Smoke', lastName: 'Admin' },
    { merge: true },
  );

  return { hospitalId: hospitalRef.id, admin: { email, password, uid: user.uid } };
}

async function cleanup(db, auth, seeded) {
  if (seeded) {
    await auth.deleteUser(seeded.admin.uid).catch(() => {});
    await db.doc(`users/${seeded.admin.uid}`).delete().catch(() => {});
    await db.doc(`hospitals/${seeded.hospitalId}`).delete().catch(() => {});
    // The new physician account was never created by this script (see
    // seed()'s own comment) — look it up by its known, deterministic
    // email instead of an id this script never had.
    const newUser = await auth.getUserByEmail(NEW_USER_EMAIL).catch(() => null);
    if (newUser) {
      await auth.deleteUser(newUser.uid).catch(() => {});
      await db.doc(`users/${newUser.uid}`).delete().catch(() => {});
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
        (user.email.startsWith('smoke-admin-onboarding-') || user.email.startsWith('smoke-physician-onboarding-')) &&
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
  console.log('Seeded hospital:', HOSPITAL_NAME);
  console.log('New physician account (created by the test itself):', NEW_USER_EMAIL);

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
    // createUser (functions/src/admin.ts) deliberately never sets
    // emailVerified — a real admin-created employee genuinely needs to
    // verify their real inbox, same as production. But MfaSetupScreen
    // gates TOTP enrollment on exactly that flag (Firebase itself
    // requires a verified email before it'll enroll a factor) and
    // there's no way for an automated test to click a real email link —
    // the same class of gap as TOTP having no server-side shortcut, just
    // the opposite direction: there the Admin SDK can't help at all,
    // here it's the one thing that *can* stand in for a real click.
    // Confirmed for real: an ems-side sibling of this exact scenario
    // (run-ems-onboarding-e2e.mjs) failed completeMfaEnrollment "Bad
    // state: No element" on every single attempt of its own retry budget
    // (2026-08-31 CI run) — not a timing race at all, the account just
    // never got past the static "Verify your email" screen, which never
    // renders mfa_secret_key. first_login_test.dart's own job is testing
    // the real set-password/MFA flow, not email verification, so this
    // flips the one flag standing in its way rather than trying to
    // fabricate a fake inbox click.
    const newUser = await auth.getUserByEmail(NEW_USER_EMAIL);
    await auth.updateUser(newUser.uid, { emailVerified: true });

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
} finally {
  await cleanup(db, auth, seeded);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
