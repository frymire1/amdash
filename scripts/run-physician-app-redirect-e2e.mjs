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
// The wrong-app account is seeded directly via the Admin SDK — not, as an
// earlier version of this script did, by driving the real admin app's
// create-user UI (create_user_test.dart). See run-ems-app-redirect-e2e.mjs's
// own header comment for the full reasoning: only user_flow_test.dart
// (admin's own canonical create-user test) needs to verify the real
// createUser flow, including its real welcome-email send — every other
// script that only needed the resulting "no password yet" account state
// was redundantly re-triggering that same real send on every CI run.
// Dropping the real UI drive here also means this script no longer needs
// a throwaway admin account at all, or Chrome against the admin app.
//
// One script, one call — seed → run wrong_app_login_test.dart against
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
const PHYSICIAN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'physician');

const RUN_ID = Date.now();
// Deliberately a different prefix than run-physician-onboarding-e2e.mjs's
// own smoke-physician-onboarding- account and run-ems-app-redirect-e2e.mjs's
// own smoke-physician-wrongapp2- account, so this script's own broad sweep
// can't collide with a concurrently-running sibling job's state (same
// reasoning as every other onboarding script's own cleanup() comment).
const WRONG_APP_USER_EMAIL = `smoke-ems-physredirect-${RUN_ID}@amdash-e2e.test`;

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
    role: ['ems'],
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
      if (user.email?.startsWith('smoke-ems-physredirect-') && isOldEnoughToSweep(user.email)) {
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

let seeded;
let exitCode = 1;
try {
  seeded = await seed(db);
  console.log('Seeded wrong-app physician account (Admin SDK, no real welcome email):', WRONG_APP_USER_EMAIL);

  exitCode = await runPatrolTest({
    appDir: PHYSICIAN_APP_DIR,
    target: 'patrol_test/wrong_app_login_test.dart',
    // No SMOKE_NEW_PASSWORD — wrong_app_login_test.dart is rejected right
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
