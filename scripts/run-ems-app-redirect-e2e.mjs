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
// One script, one call — seed → create the wrong-app account via the admin
// app's own UI (Chrome) → run wrong_app_login_test.dart against EMS's own
// Chrome build (already exercised by run-ems-patrol-test.mjs in the same
// job) → teardown. Mirrors run-physician-onboarding-e2e.mjs's own shape,
// not run-ems-onboarding-e2e.mjs's --seed-only/--create-user/--teardown
// split — that split exists specifically because Android doesn't go
// through runPatrolTest's `patrol test` device runs at all (see that
// file's own header comment); this leg is Chrome-only now, so nothing
// about it needs splitting across job boundaries.
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
const ADMIN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'admin');
const EMS_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'ems');

const RUN_ID = Date.now();
// Deliberately a different prefix than run-ems-onboarding-e2e.mjs's own
// smoke-admin-onboarding-/smoke-physician-wrongapp- accounts, so this
// script's own broad sweep can't collide with a concurrently-running
// sibling job's state (same reasoning as every other onboarding script's
// own cleanup() comment).
const ADMIN_EMAIL = `smoke-admin-wrongapp-${RUN_ID}@amdash-e2e.test`;
const ADMIN_PASSWORD = 'SmokeTest123';
const WRONG_APP_USER_EMAIL = `smoke-physician-wrongapp2-${RUN_ID}@amdash-e2e.test`;

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
        (user.email.startsWith('smoke-admin-wrongapp-') || user.email.startsWith('smoke-physician-wrongapp2-')) &&
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

const credentialPath = initFirebaseAdmin('emswrongapp');
const db = getFirestore();
const auth = getAuth();

let admin;
let exitCode = 1;
try {
  admin = await seed(db);
  console.log('Created throwaway admin account:', ADMIN_EMAIL);
  console.log('Wrong-app EMS account (created by the test itself):', WRONG_APP_USER_EMAIL);

  const createExitCode = await runPatrolTest({
    appDir: ADMIN_APP_DIR,
    target: 'patrol_test/create_user_test.dart',
    dartDefines: {
      SMOKE_EMAIL: ADMIN_EMAIL,
      SMOKE_PASSWORD: ADMIN_PASSWORD,
      SMOKE_NEW_USER_EMAIL: WRONG_APP_USER_EMAIL,
      SMOKE_NEW_USER_ROLE: 'physician',
    },
  });

  if (createExitCode !== 0) {
    console.log('\n❌ Admin create-user step failed — skipping the wrong-app login step (account was never created).');
    exitCode = createExitCode;
  } else {
    exitCode = await runPatrolTest({
      appDir: EMS_APP_DIR,
      target: 'patrol_test/wrong_app_login_test.dart',
      // No SMOKE_PASSWORD — wrong_app_login_test.dart is rejected right
      // after email, before a password is ever relevant (see its own
      // header comment).
      dartDefines: { SMOKE_EMAIL: WRONG_APP_USER_EMAIL },
    });
  }
} finally {
  await cleanup(db, auth, admin);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
