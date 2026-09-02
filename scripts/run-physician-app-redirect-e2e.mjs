#!/usr/bin/env node
// Cross-app e2e, physician's wrong-app rejection leg — split out of
// run-physician-onboarding-e2e.mjs into its own self-contained script, the
// same way EMS's equivalent leg was (see run-ems-app-redirect-e2e.mjs's
// own header comment for the original reasoning: nothing about "enter
// email, tap Continue, wait for 'Access denied' text, assert the right
// app link shows" is platform-specific, so there's no reason for it to
// share a script/build with the real onboarding leg, which genuinely does
// need its own sequential run).
//
// This particular split has a second, more specific reason too: a real
// attempt at *merging* these two physician scenarios into one
// `patrolTest` block (so they'd share one build) hit a hard wall — the
// real onboarding leg ends signed in, and getting back to a clean
// LoginScreen for this leg requires signing out, but
// AuthService.signOut() (amdash_core) deliberately calls
// FirebaseFirestore.terminate() + a full page reload on web (a documented
// fix for a real prior bug — see that method's own comment — not
// something to work around). Confirmed for real: calling it mid-test
// threw `FirebaseError: [code=failed-precondition]: The client has
// already been terminated`, the same class of failure Patrol's own
// reload *between* separate patrolTest blocks causes (see
// run-ems-app-redirect-e2e.mjs's own EMS-side merge, which avoided this
// entirely by reusing one already-signed-in account across both its own
// scenarios — no sign-out ever needed there). No scenario ordering avoids
// it here: whichever runs second still needs a clean LoginScreen, and the
// only in-app way there is a sign-out button that reloads. Splitting into
// two independent scripts/jobs — this file and
// run-physician-onboarding-e2e.mjs — sidesteps the problem entirely by
// never needing a mid-session transition at all.
//
// One script, one call — seed → create the wrong-app account via the admin
// app's own UI (Chrome) → run wrong_app_login_test.dart against
// physician's own Chrome build (already exercised by
// run-physician-patrol-test.mjs in a sibling job) → teardown. Mirrors
// run-ems-app-redirect-e2e.mjs's own shape exactly.
//
// Usage: node scripts/run-physician-app-redirect-e2e.mjs
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
// Deliberately different prefixes than run-physician-onboarding-e2e.mjs's
// own smoke-admin-onboarding-/smoke-physician-onboarding- accounts and
// run-ems-app-redirect-e2e.mjs's own smoke-admin-wrongapp-/
// smoke-physician-wrongapp2- accounts, so this script's own broad sweep
// can't collide with a concurrently-running sibling job's state (same
// reasoning as every other onboarding script's own cleanup() comment).
const ADMIN_EMAIL = `smoke-admin-physredirect-${RUN_ID}@amdash-e2e.test`;
const ADMIN_PASSWORD = 'SmokeTest123';
const WRONG_APP_USER_EMAIL = `smoke-ems-physredirect-${RUN_ID}@amdash-e2e.test`;

async function seed(db) {
  const organizationId = await findOrganizationId(db, 'test-org');
  const user = await getAuth().createUser({ email: ADMIN_EMAIL, password: ADMIN_PASSWORD, emailVerified: true });
  await db.doc(`users/${user.uid}`).set(
    { email: ADMIN_EMAIL, role: ['admin'], organizationId, firstName: 'Smoke', lastName: 'Admin' },
    { merge: true },
  );
  return { uid: user.uid };
}

async function cleanup(db, auth, admin) {
  if (admin) {
    await auth.deleteUser(admin.uid).catch(() => {});
    await db.doc(`users/${admin.uid}`).delete().catch(() => {});
    const newUser = await auth.getUserByEmail(WRONG_APP_USER_EMAIL).catch(() => null);
    if (newUser) {
      await auth.deleteUser(newUser.uid).catch(() => {});
      await db.doc(`users/${newUser.uid}`).delete().catch(() => {});
    }
  }

  // Age-guarded broad sweep for anything an interrupted run left behind —
  // see isOldEnoughToSweep's own comment for why this exists alongside the
  // specific deletes above.
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (
        user.email &&
        (user.email.startsWith('smoke-admin-physredirect-') || user.email.startsWith('smoke-ems-physredirect-')) &&
        isOldEnoughToSweep(user.email)
      ) {
        await auth.deleteUser(user.uid);
        await db.doc(`users/${user.uid}`).delete().catch(() => {});
        deletedUsers++;
      }
    }
    pageToken = page.pageToken;
  } while (pageToken);

  console.log(`Cleanup: removed ${deletedUsers} throwaway user(s).`);
}

const credentialPath = initFirebaseAdmin('physicianappredirect');
const db = getFirestore();
const auth = getAuth();

let admin;
let exitCode = 1;
try {
  admin = await seed(db);
  console.log('Created throwaway admin account:', ADMIN_EMAIL);
  console.log('Wrong-app physician account (created by the test itself):', WRONG_APP_USER_EMAIL);

  const createExitCode = await runPatrolTest({
    appDir: ADMIN_APP_DIR,
    target: 'patrol_test/create_user_test.dart',
    dartDefines: {
      SMOKE_EMAIL: ADMIN_EMAIL,
      SMOKE_PASSWORD: ADMIN_PASSWORD,
      SMOKE_NEW_USER_EMAIL: WRONG_APP_USER_EMAIL,
      SMOKE_NEW_USER_ROLE: 'ems',
    },
  });

  if (createExitCode !== 0) {
    console.log('\n❌ Admin create-user step failed — skipping the wrong-app login step (account was never created).');
    exitCode = createExitCode;
  } else {
    exitCode = await runPatrolTest({
      appDir: PHYSICIAN_APP_DIR,
      target: 'patrol_test/wrong_app_login_test.dart',
      // No SMOKE_NEW_PASSWORD — wrong_app_login_test.dart is rejected
      // right after email, before a password is ever relevant (see its
      // own header comment).
      dartDefines: { SMOKE_EMAIL: WRONG_APP_USER_EMAIL },
    });
  }
} finally {
  await cleanup(db, auth, admin);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
