#!/usr/bin/env node
// Cross-app, cross-platform e2e: an admin account creates a new EMS user
// through the admin app's own real UI (no password, nothing pre-seeded —
// see admin/patrol_test/create_user_test.dart), and that exact account
// then completes its own real first-ever sign-in (set a password, enroll
// MFA) on a real Android device via Firebase Test Lab (see
// ems/patrol_test/first_login_test.dart) — deliberately Android, not
// Chrome, unlike this script's physician-onboarding sibling
// (run-physician-onboarding-e2e.mjs): EMS crews use the native app in the
// field, not the web build (which exists only for this repo's own Chrome
// e2e coverage — see ems_test.dart's header).
//
// Split into --seed-only/--create-user/--teardown modes, like
// run-ems-patrol-test.mjs, rather than one self-contained run — same
// reason: Android e2e doesn't go through runPatrolTest's `patrol test`
// device runs at all (see that file's own header comment); it's
// `patrol build android` + `gcloud firebase test android run` invoked
// directly from ci.yml's flutter-android-e2e-ems-onboarding job. The one
// new wrinkle here versus that job's existing shape: admin has no native
// Android/iOS build at all (web-only), so the admin half of this flow
// still has to run via a real `patrol test --device chrome` call (this
// script's --create-user mode) — that call actually happens in the
// flutter-android-e2e-seed job instead (see its own steps), which installs
// Playwright/xvfb for exactly this one step, alongside its existing
// Test-Lab-only setup, and uploads the resulting account as an artifact
// for -ems-onboarding to consume.
//
// The matching failure-state leg (an admin-created *physician*-role
// account attempting to sign into the EMS app instead) used to live here
// too, but doesn't need Android at all — see run-ems-app-redirect-e2e.mjs,
// which now owns that scenario entirely, self-contained and Chrome-only.
//
// Usage:
//   node scripts/run-ems-onboarding-e2e.mjs --seed-only --account-json=<path>
//     Seeds the throwaway admin account, computes the new account's
//     email/password (not created here — see above), and writes it all to
//     --account-json. Exits 0 without running any Patrol test.
//   node scripts/run-ems-onboarding-e2e.mjs --create-user --account-json=<path>
//     Reads --account-json, runs admin/patrol_test/create_user_test.dart
//     via Chrome to actually create the account, and exits nonzero if
//     creation failed.
//   node scripts/run-ems-onboarding-e2e.mjs --teardown --account-json=<path>
//     Reads --account-json, tears the account down (whether or not it
//     actually got created), deletes the file, and exits.
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
import { runPatrolTest } from './lib/run-patrol.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const ADMIN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'admin');

const DEFAULT_ACCOUNT_JSON_PATH = path.join(os.tmpdir(), 'amdash-ems-onboarding-account.json');

async function seedAccount(db) {
  const organizationId = await findOrganizationId(db, 'test-org');
  const runId = Date.now();

  const email = `smoke-admin-onboarding-${runId}@amdash-e2e.test`;
  const password = 'SmokeTest123';
  const user = await getAuth().createUser({ email, password, emailVerified: true });
  await db.doc(`users/${user.uid}`).set(
    { email, role: ['admin'], organizationId, firstName: 'Smoke', lastName: 'Admin' },
    { merge: true },
  );

  return {
    admin: { email, password, uid: user.uid },
    newUserEmail: `smoke-ems-onboarding-${runId}@amdash-e2e.test`,
    // Must satisfy passwordMeetsComplexityRequirements (functions/src/
    // auth.ts) — 8+ chars, an uppercase letter, a number, a special
    // character, same as every other onboarding password this suite
    // generates.
    newUserPassword: 'OnboardTest1!',
  };
}

async function cleanup(db, auth, account) {
  if (account) {
    await auth.deleteUser(account.admin.uid).catch(() => {});
    await db.doc(`users/${account.admin.uid}`).delete().catch(() => {});
    // The new EMS account is never created by this script — look it up by
    // its known, deterministic email instead of an id this script never
    // had; harmless no-op if --create-user never actually got to it.
    const newUser = await auth.getUserByEmail(account.newUserEmail).catch(() => null);
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
        (user.email.startsWith('smoke-admin-onboarding-') || user.email.startsWith('smoke-ems-onboarding-')) &&
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

const args = process.argv.slice(2);
const mode = args.find((a) => a.startsWith('--seed-only') || a.startsWith('--create-user') || a.startsWith('--teardown'));
const accountJsonArg = args.find((a) => a.startsWith('--account-json='));
const accountJsonPath = accountJsonArg ? accountJsonArg.split('=')[1] : DEFAULT_ACCOUNT_JSON_PATH;

if (!mode) {
  console.error('Pass exactly one of --seed-only, --create-user, or --teardown.');
  process.exit(1);
}

const credentialPath = initFirebaseAdmin('emsonboarding');
const db = getFirestore();
const auth = getAuth();

if (mode.startsWith('--seed-only')) {
  const account = await seedAccount(db);
  fs.writeFileSync(accountJsonPath, JSON.stringify(account));
  console.log('Created throwaway admin account:', account.admin.email);
  console.log('New EMS account (created by --create-user, not here):', account.newUserEmail);
  if (credentialPath) fs.unlinkSync(credentialPath);
  process.exit(0);
}

if (mode.startsWith('--create-user')) {
  const account = JSON.parse(fs.readFileSync(accountJsonPath, 'utf8'));

  const newUserExitCode = await runPatrolTest({
    appDir: ADMIN_APP_DIR,
    target: 'patrol_test/create_user_test.dart',
    dartDefines: {
      SMOKE_EMAIL: account.admin.email,
      SMOKE_PASSWORD: account.admin.password,
      SMOKE_NEW_USER_EMAIL: account.newUserEmail,
      SMOKE_NEW_USER_ROLE: 'ems',
    },
  });
  console.log(
    newUserExitCode === 0 ? '\n✅ Created the real EMS onboarding account.' : '\n❌ Failed to create the real EMS onboarding account.',
  );

  // createUser (functions/src/admin.ts) deliberately never sets
  // emailVerified — a real admin-created employee genuinely needs to
  // verify their real inbox, same as production. But MfaSetupScreen gates
  // TOTP enrollment on exactly that flag (Firebase itself requires a
  // verified email before it'll enroll a factor) and there's no way for
  // an automated test to click a real email link — the same class of gap
  // as TOTP having no server-side shortcut, just the opposite direction:
  // there the Admin SDK can't help at all, here it's the one thing that
  // *can* stand in for a real click. Confirmed for real: first_login_test
  // .dart's completeMfaEnrollment failed "Bad state: No element" on every
  // single attempt of its own retry budget (2026-08-31 CI run) — not a
  // timing race at all, the account just never got past the static
  // "Verify your email" screen, which never renders mfa_secret_key.
  // first_login_test.dart's own job is testing the real set-password/MFA
  // flow, not email verification, so this flips the one flag standing in
  // its way rather than trying to fabricate a fake inbox click.
  if (newUserExitCode === 0) {
    const newUser = await auth.getUserByEmail(account.newUserEmail);
    await auth.updateUser(newUser.uid, { emailVerified: true });
  }

  if (credentialPath) fs.unlinkSync(credentialPath);
  process.exit(newUserExitCode);
}

// --teardown
const account = fs.existsSync(accountJsonPath) ? JSON.parse(fs.readFileSync(accountJsonPath, 'utf8')) : null;
await cleanup(db, auth, account);
if (fs.existsSync(accountJsonPath)) fs.unlinkSync(accountJsonPath);
if (credentialPath) fs.unlinkSync(credentialPath);
