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
// directly from ci.yml's flutter-android-e2e job. The one new wrinkle
// here versus that job's existing shape: admin has no native Android/iOS
// build at all (web-only), so the admin half of this flow still has to
// run via a real `patrol test --device chrome` call (this script's
// --create-user mode) — flutter-android-e2e now installs Playwright/xvfb
// for exactly this one step, alongside its existing Test-Lab-only setup.
//
// Also seeds/creates a second account for the matching failure state: an
// admin-created *physician*-role account attempting to sign into the EMS
// app instead — rejected right after email (checkAccountStatus's own
// roleAllowed field, see functions/src/auth.ts), before a password is
// ever relevant, landing on AccessDeniedScreen, never HomeScreen. See
// ems/patrol_test/wrong_app_login_test.dart. ci.yml runs that as its own
// separate `patrol build android` + Test Lab invocation (a distinct
// target file needs its own APK), reading this same --account-json for the
// wrongAppUserEmail/wrongAppUserPassword fields --create-user writes.
//
// Usage:
//   node scripts/run-ems-onboarding-e2e.mjs --seed-only --account-json=<path>
//     Seeds the throwaway admin account, computes both new accounts'
//     email/password (neither created here — see above), and writes it
//     all to --account-json. Exits 0 without running any Patrol test.
//   node scripts/run-ems-onboarding-e2e.mjs --create-user --account-json=<path>
//     Reads --account-json, runs admin/patrol_test/create_user_test.dart
//     via Chrome twice (once per role) to actually create both accounts,
//     and exits nonzero if either creation failed.
//   node scripts/run-ems-onboarding-e2e.mjs --teardown --account-json=<path>
//     Reads --account-json, tears every account it named down (whether or
//     not either one actually got created), deletes the file, and exits.
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

  const adminEmail = `smoke-admin-onboarding-${runId}@amdash-e2e.test`;
  const adminPassword = 'SmokeTest123';
  const adminUser = await getAuth().createUser({ email: adminEmail, password: adminPassword, emailVerified: true });
  await db.doc(`users/${adminUser.uid}`).set(
    { email: adminEmail, role: ['admin'], organizationId, firstName: 'Smoke', lastName: 'Admin' },
    { merge: true },
  );

  return {
    admin: { email: adminEmail, password: adminPassword, uid: adminUser.uid },
    newUserEmail: `smoke-ems-onboarding-${runId}@amdash-e2e.test`,
    // Deliberately a *different* prefix (smoke-physician-wrongapp-, not
    // smoke-physician-onboarding-) so this script's own broad sweep can't
    // collide with a sibling run-physician-onboarding-e2e.mjs job's own
    // smoke-physician-onboarding- accounts.
    wrongAppUserEmail: `smoke-physician-wrongapp-${runId}@amdash-e2e.test`,
    // Must satisfy passwordMeetsComplexityRequirements (functions/src/
    // auth.ts) — 8+ chars, an uppercase letter, a number, a special
    // character, same as every other onboarding password this suite
    // generates. Shared by both accounts — nothing meaningful is gained
    // by generating two.
    newUserPassword: 'OnboardTest1!',
  };
}

async function cleanup(db, auth, account) {
  if (account) {
    await auth.deleteUser(account.admin.uid).catch(() => {});
    await db.doc(`users/${account.admin.uid}`).delete().catch(() => {});
    // Neither the new EMS account nor the wrong-app physician account is
    // ever created by this script — look them up by their known,
    // deterministic emails instead of ids this script never had; harmless
    // no-op for whichever --create-user never actually got to.
    for (const email of [account.newUserEmail, account.wrongAppUserEmail]) {
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
          user.email.startsWith('smoke-ems-onboarding-') ||
          user.email.startsWith('smoke-physician-wrongapp-')) &&
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
  console.log('Wrong-app physician account (created by --create-user, not here):', account.wrongAppUserEmail);
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

  // Runs regardless of how the first creation went — an independent
  // account, no reason to skip it just because the other had trouble.
  const wrongAppExitCode = await runPatrolTest({
    appDir: ADMIN_APP_DIR,
    target: 'patrol_test/create_user_test.dart',
    dartDefines: {
      SMOKE_EMAIL: account.admin.email,
      SMOKE_PASSWORD: account.admin.password,
      SMOKE_NEW_USER_EMAIL: account.wrongAppUserEmail,
      SMOKE_NEW_USER_ROLE: 'physician',
    },
  });
  console.log(
    wrongAppExitCode === 0
      ? '\n✅ Created the wrong-app (physician) onboarding account.'
      : '\n❌ Failed to create the wrong-app (physician) onboarding account.',
  );

  if (credentialPath) fs.unlinkSync(credentialPath);
  process.exit(newUserExitCode !== 0 ? newUserExitCode : wrongAppExitCode);
}

// --teardown
const account = fs.existsSync(accountJsonPath) ? JSON.parse(fs.readFileSync(accountJsonPath, 'utf8')) : null;
await cleanup(db, auth, account);
if (fs.existsSync(accountJsonPath)) fs.unlinkSync(accountJsonPath);
if (credentialPath) fs.unlinkSync(credentialPath);
