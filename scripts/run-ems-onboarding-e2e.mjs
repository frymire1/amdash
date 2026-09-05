#!/usr/bin/env node
// Cross-app, cross-platform e2e: a new EMS user, seeded with no password
// (mirroring exactly what admin's real createUser Cloud Function itself
// would have produced — see below), completes its own real first-ever
// sign-in (set a password, enroll MFA) on a real Android device via
// Firebase Test Lab (see ems/patrol_test/first_login_test.dart) —
// deliberately Android, not Chrome, unlike this script's physician-
// onboarding sibling (run-physician-onboarding-e2e.mjs): EMS crews use the
// native app in the field, not the web build (which exists only for this
// repo's own Chrome e2e coverage — see ems_test.dart's header).
//
// The account is seeded directly via the Admin SDK now, not by driving
// the admin app's real create-user UI (create_user_test.dart) the way an
// earlier version of this script did (that version's own --create-user
// mode, since removed, ran via `patrol test --device chrome` from the
// flutter-android-e2e-seed job — Playwright/xvfb was only ever installed
// there for this one step). That real UI flow's own createUser Cloud
// Function (functions/src/admin.ts) does exactly two things beyond
// creating the Auth user itself: writes users/{uid}, and sends a real
// welcome email via Resend. This script's own job — verifying EMS's real
// first-login flow on a real Android device — only depends on the
// *resulting account state* (no password, correct role/org), which a
// direct getAuth().createUser({ email }) produces identically, with no
// callable and no email. Only user_flow_test.dart (admin's own canonical
// create-user test, run by run-admin-patrol-test.mjs) needs to verify the
// real createUser flow itself, including its real email side effect —
// this script, its physician-onboarding sibling, and both wrong-app
// scripts were redundantly re-triggering that same real send on every CI
// run until this was noticed.
//
// The matching failure-state leg (an admin-created *physician*-role
// account attempting to sign into the EMS app instead) used to live here
// too, but doesn't need Android at all — see run-ems-app-redirect-e2e.mjs,
// which now owns that scenario entirely, self-contained and Chrome-only.
//
// Split into --seed-only/--teardown modes (a --create-user mode used to
// sit between them — see above for why it's gone), like
// run-ems-patrol-test.mjs, rather than one self-contained run — same
// reason: Android e2e doesn't go through runPatrolTest's `patrol test`
// device runs at all (see that file's own header comment); it's
// `patrol build android` + `gcloud firebase test android run` invoked
// directly from ci.yml's flutter-android-e2e-ems-onboarding job.
//
// Usage:
//   node scripts/run-ems-onboarding-e2e.mjs --seed-only --account-json=<path>
//     Seeds the new EMS account (Admin SDK, no password, no real email)
//     and writes it to --account-json. Exits 0.
//   node scripts/run-ems-onboarding-e2e.mjs --teardown --account-json=<path>
//     Reads --account-json, tears the account down, deletes the file, and
//     exits.
// Requires: flutter + patrol_cli on PATH (or edit FLUTTER_BIN/PATROL_BIN in
// scripts/lib/run-patrol.mjs to match your machine), a cached `firebase
// login` CLI session (or GOOGLE_APPLICATION_CREDENTIALS set, e.g. in CI).

import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { findOrganizationId, initFirebaseAdmin, isOldEnoughToSweep } from './lib/firebase-admin-cli.mjs';

const DEFAULT_ACCOUNT_JSON_PATH = path.join(os.tmpdir(), 'amdash-ems-onboarding-account.json');

async function seedAccount(db) {
  const organizationId = await findOrganizationId(db, 'test-org');
  const runId = Date.now();
  const newUserEmail = `smoke-ems-onboarding-${runId}@amdash-e2e.test`;

  // Mirrors createUser's own real side effects (functions/src/admin.ts) —
  // an Auth user with no password, plus a matching users/{uid} doc —
  // without driving the real admin UI/callable to get there. See this
  // file's own header comment for why. emailVerified: true directly
  // (unlike real createUser, which never sets it) — MfaSetupScreen gates
  // TOTP enrollment on exactly that flag, and there's no way for an
  // automated test to click a real inbox-verification link — nothing here
  // depends on the account starting out unverified, so setting it at
  // creation time is equally correct and one Admin SDK call cheaper.
  const user = await getAuth().createUser({ email: newUserEmail, emailVerified: true });
  await db.doc(`users/${user.uid}`).set({
    email: newUserEmail,
    firstName: 'Patrol',
    lastName: 'Onboarding',
    role: ['ems'],
    organizationId,
  });

  return {
    uid: user.uid,
    newUserEmail,
    // Must satisfy passwordMeetsComplexityRequirements (functions/src/
    // auth.ts) — 8+ chars, an uppercase letter, a number, a special
    // character, same as every other onboarding password this suite
    // generates.
    newUserPassword: 'OnboardTest1!',
  };
}

async function cleanup(db, auth, account) {
  if (account) {
    await auth.deleteUser(account.uid).catch(() => {});
    await db.doc(`users/${account.uid}`).delete().catch(() => {});
  }

  // Age-guarded broad sweep for anything an interrupted run left behind —
  // see isOldEnoughToSweep's own comment for why this exists alongside
  // the specific delete above.
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (user.email?.startsWith('smoke-ems-onboarding-') && isOldEnoughToSweep(user.email)) {
        await auth.deleteUser(user.uid);
        await db.doc(`users/${user.uid}`).delete().catch(() => {});
        deletedUsers++;
      }
    }
    pageToken = page.pageToken;
  } while (pageToken);

  console.log(`Cleanup: removed ${deletedUsers} throwaway user(s).`);
}

const args = process.argv.slice(2);
const mode = args.find((a) => a.startsWith('--seed-only') || a.startsWith('--teardown'));
const accountJsonArg = args.find((a) => a.startsWith('--account-json='));
const accountJsonPath = accountJsonArg ? accountJsonArg.split('=')[1] : DEFAULT_ACCOUNT_JSON_PATH;

if (!mode) {
  console.error('Pass exactly one of --seed-only or --teardown.');
  process.exit(1);
}

const credentialPath = initFirebaseAdmin('emsonboarding');
const db = getFirestore();
const auth = getAuth();

if (mode.startsWith('--seed-only')) {
  const account = await seedAccount(db);
  fs.writeFileSync(accountJsonPath, JSON.stringify(account));
  console.log('Seeded new EMS account (Admin SDK, no real welcome email):', account.newUserEmail);
  if (credentialPath) fs.unlinkSync(credentialPath);
  process.exit(0);
}

// --teardown
const account = fs.existsSync(accountJsonPath) ? JSON.parse(fs.readFileSync(accountJsonPath, 'utf8')) : null;
await cleanup(db, auth, account);
if (fs.existsSync(accountJsonPath)) fs.unlinkSync(accountJsonPath);
if (credentialPath) fs.unlinkSync(credentialPath);
