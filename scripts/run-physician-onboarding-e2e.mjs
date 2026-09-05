#!/usr/bin/env node
// Cross-app e2e: a new physician user, seeded with no password (mirroring
// exactly what admin's real createUser Cloud Function itself would have
// produced — see below), completes its own real first-ever sign-in (set a
// password, enroll MFA, set a work location) through the physician app's
// own UI (see physician/patrol_test/first_login_test.dart).
//
// The account is seeded directly via the Admin SDK now, not by driving
// the admin app's real create-user UI (create_user_test.dart) the way an
// earlier version of this script did. That real UI flow's own createUser
// Cloud Function (functions/src/admin.ts) does exactly two things beyond
// creating the Auth user itself: writes users/{uid}, and sends a real
// welcome email via Resend. This script's own job — verifying physician's
// real first-login flow — only depends on the *resulting account state*
// (no password, correct role/org), which a direct
// getAuth().createUser({ email }) produces identically, with no callable
// and no email. Only user_flow_test.dart (admin's own canonical
// create-user test, run by run-admin-patrol-test.mjs) needs to verify the
// real createUser flow itself, including its real email side effect —
// this script, its own wrong-app sibling, and both EMS-side equivalents
// were redundantly re-triggering that same real send on every CI run
// until this was noticed. Dropping the real UI drive here also means this
// script no longer needs a throwaway admin account at all, or Chrome
// against the admin app.
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

  // Mirrors createUser's own real side effects (functions/src/admin.ts) —
  // an Auth user with no password, plus a matching users/{uid} doc —
  // without driving the real admin UI/callable to get there. See this
  // file's own header comment for why. emailVerified: true directly
  // (unlike real createUser, which never sets it) — MfaSetupScreen gates
  // TOTP enrollment on exactly that flag, and there's no way for an
  // automated test to click a real inbox-verification link (see the old
  // version of this comment, previously attached to a separate post-hoc
  // auth.updateUser flip, for that reasoning in full) — nothing here
  // depends on the account starting out unverified, so setting it at
  // creation time is equally correct and one Admin SDK call cheaper.
  const user = await getAuth().createUser({ email: NEW_USER_EMAIL, emailVerified: true });
  await db.doc(`users/${user.uid}`).set({
    email: NEW_USER_EMAIL,
    firstName: 'Patrol',
    lastName: 'Onboarding',
    role: ['physician'],
    organizationId,
  });

  return { hospitalId: hospitalRef.id, uid: user.uid };
}

async function cleanup(db, auth, seeded) {
  if (seeded) {
    await auth.deleteUser(seeded.uid).catch(() => {});
    await db.doc(`users/${seeded.uid}`).delete().catch(() => {});
    await db.doc(`hospitals/${seeded.hospitalId}`).delete().catch(() => {});
  }

  // Age-guarded broad sweep for anything an interrupted run left behind —
  // see isOldEnoughToSweep's own comment for why this exists alongside
  // the specific deletes above.
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (user.email?.startsWith('smoke-physician-onboarding-') && isOldEnoughToSweep(user.email)) {
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
  console.log('Seeded hospital:', HOSPITAL_NAME);
  console.log('Seeded new physician account (Admin SDK, no real welcome email):', NEW_USER_EMAIL);

  exitCode = await runPatrolTest({
    appDir: PHYSICIAN_APP_DIR,
    target: 'patrol_test/first_login_test.dart',
    dartDefines: {
      SMOKE_EMAIL: NEW_USER_EMAIL,
      SMOKE_NEW_PASSWORD: NEW_USER_PASSWORD,
      SMOKE_HOSPITAL: HOSPITAL_NAME,
    },
  });
} finally {
  await cleanup(db, auth, seeded);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
