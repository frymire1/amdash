#!/usr/bin/env node
// Cross-app e2e, EMS's wrong-app rejection leg — split out of
// run-ems-onboarding-e2e.mjs into its own self-contained script: unlike
// that script's real onboarding leg (first_login_test.dart, which genuinely
// needs a real Android device — MFA enrollment behavior EMS crews actually
// hit), this test has nothing platform-specific in it at all (enter email,
// tap Continue, wait for 'Access denied' text, assert the right app link
// shows) — the same shape of check as physician's own wrong-app leg, which
// already runs on Chrome inside run-physician-onboarding-e2e.mjs. Moved
// here, and off Android Test Lab entirely, once that was noticed — was
// previously bundled into run-ems-onboarding-e2e.mjs's own --create-user/
// Android-Test-Lab-build flow for no reason beyond having been added
// alongside the real onboarding leg originally.
//
// The wrong-app account is seeded directly via the Admin SDK — not, as an
// earlier version of this script did, by driving the real admin app's
// create-user UI (create_user_test.dart). That real UI flow's own
// createUser Cloud Function (functions/src/admin.ts) does exactly two
// things beyond creating the Auth user itself: writes users/{uid}, and
// sends a real welcome email via Resend. This test's own job — "does an
// admin-created, no-password account get rejected by the wrong app" —
// only depends on the *resulting account state*, which a direct
// getAuth().createUser({ email }) (no password, same as createUser's own
// call) produces identically, with no callable and no email. Only
// user_flow_test.dart (admin's own canonical create-user test, run by
// run-admin-patrol-test.mjs) needs to verify the real create-user flow
// itself, including its real email side effect — every other script that
// only needed the resulting account (this one, its physician sibling, and
// both onboarding scripts) was redundantly re-triggering that same real
// send on every single CI run until this was noticed. Dropping the real
// UI drive here also means this script no longer needs a throwaway admin
// account at all, or Chrome against the admin app.
//
// One script, one call — seed → run wrong_app_login_test.dart against
// EMS's own Chrome build (already exercised by run-ems-patrol-test.mjs in
// the same job) → teardown.
//
// Usage: node scripts/run-ems-app-redirect-e2e.mjs
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

const RUN_ID = Date.now();
// Deliberately a different prefix than run-ems-onboarding-e2e.mjs's own
// smoke-ems-onboarding- account, so this script's own broad sweep can't
// collide with a concurrently-running sibling job's state (same reasoning
// as every other onboarding script's own cleanup() comment).
const WRONG_APP_USER_EMAIL = `smoke-physician-wrongapp2-${RUN_ID}@amdash-e2e.test`;

async function seed(db) {
  const organizationId = await findOrganizationId(db, 'test-org');
  // Mirrors createUser's own real side effects (functions/src/admin.ts) —
  // an Auth user with no password, plus a matching users/{uid} doc —
  // without driving the real admin UI/callable to get there. See this
  // file's own header comment for why.
  const user = await getAuth().createUser({ email: WRONG_APP_USER_EMAIL });
  await db.doc(`users/${user.uid}`).set({
    email: WRONG_APP_USER_EMAIL,
    firstName: 'Patrol',
    lastName: 'Onboarding',
    role: ['physician'],
    organizationId,
  });
  return { uid: user.uid };
}

async function cleanup(db, auth, seeded) {
  if (seeded) {
    await auth.deleteUser(seeded.uid).catch(() => {});
    await db.doc(`users/${seeded.uid}`).delete().catch(() => {});
  }

  // Age-guarded broad sweep for anything an interrupted run left behind —
  // see isOldEnoughToSweep's own comment for why this exists alongside the
  // specific delete above.
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (user.email?.startsWith('smoke-physician-wrongapp2-') && isOldEnoughToSweep(user.email)) {
        await auth.deleteUser(user.uid);
        await db.doc(`users/${user.uid}`).delete().catch(() => {});
        deletedUsers++;
      }
    }
    pageToken = page.pageToken;
  } while (pageToken);

  console.log(`Cleanup: removed ${deletedUsers} throwaway user(s).`);
}

const credentialPath = initFirebaseAdmin('emswrongapp');
const db = getFirestore();
const auth = getAuth();

let seeded;
let exitCode = 1;
try {
  seeded = await seed(db);
  console.log('Seeded wrong-app EMS account (Admin SDK, no real welcome email):', WRONG_APP_USER_EMAIL);

  exitCode = await runPatrolTest({
    appDir: EMS_APP_DIR,
    target: 'patrol_test/wrong_app_login_test.dart',
    // No SMOKE_PASSWORD — wrong_app_login_test.dart is rejected right
    // after email, before a password is ever relevant (see its own
    // header comment).
    dartDefines: { SMOKE_EMAIL: WRONG_APP_USER_EMAIL },
  });
} finally {
  await cleanup(db, auth, seeded);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
