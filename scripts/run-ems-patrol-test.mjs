#!/usr/bin/env node
// Self-contained runner for the EMS app's Patrol e2e test — same pattern
// as run-admin-patrol-test.mjs. Simpler than physician's runner: the test
// itself creates, edits, and deletes its own throwaway patient entirely
// through the app's UI (see patrol_test/ems_test.dart), so
// this script only needs to create/delete the throwaway EMS account.
// Wired into .github/workflows/ci.yml's e2e job — not a local-only dev
// tool.
//
// Written in Node/JS rather than Dart for the same reason as
// run-admin-patrol-test.mjs: needs the Firebase *Admin* SDK to seed/tear
// down real Auth + Firestore state around the Dart-side Patrol test, and
// scripts/ already has that set up.
//
// Usage:
//   node scripts/run-ems-patrol-test.mjs
//     Default: seed, run `patrol test`, teardown, all in one process — used
//     by web-e2e (Chrome). PATROL_DEVICE=android|ios overrides the default
//     'chrome' device — 'android'/'ios' get resolved to the actual connected
//     emulator/simulator device id at run time (see
//     scripts/lib/run-patrol.mjs's resolveDeviceId).
//   node scripts/run-ems-patrol-test.mjs --seed-only [--account-json=<path>]
//     Seeds only, writes the seeded account to --account-json (default: an
//     os.tmpdir() path) and exits 0 without running patrol or tearing down.
//     Used ahead of `patrol build` in the Firebase Test Lab
//     (android-e2e/ios-e2e) workflows, where the app is built once with
//     these values baked in as --dart-define flags rather than run locally
//     via `patrol test`.
//   node scripts/run-ems-patrol-test.mjs --teardown [--account-json=<path>]
//     Reads --account-json, tears the seeded state down, deletes the file,
//     and exits. Used after the `gcloud firebase test ... run` step in the
//     Test Lab workflows — a separate step from seeding, so it must be
//     invoked independently rather than via the try/finally below.
// Requires: flutter + patrol_cli on PATH (or edit scripts/lib/run-patrol.mjs
// to match your machine), a cached `firebase login` CLI session (or
// GOOGLE_APPLICATION_CREDENTIALS set, e.g. in CI).

import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { findOrganizationId, initFirebaseAdmin } from './lib/firebase-admin-cli.mjs';
import { runPatrolTest } from './lib/run-patrol.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const EMS_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'ems');
const DEFAULT_ACCOUNT_JSON_PATH = path.join(os.tmpdir(), 'amdash-ems-smoke-account.json');

function parseArgs(argv) {
  const seedOnly = argv.includes('--seed-only');
  const teardown = argv.includes('--teardown');
  if (seedOnly && teardown) throw new Error('--seed-only and --teardown are mutually exclusive.');
  const accountJsonArg = argv.find((arg) => arg.startsWith('--account-json='));
  const accountJsonPath = accountJsonArg ? accountJsonArg.slice('--account-json='.length) : DEFAULT_ACCOUNT_JSON_PATH;
  return { seedOnly, teardown, accountJsonPath };
}

async function createSmokeEmsAccount(db) {
  const organizationId = await findOrganizationId(db, 'test-org');
  const email = `smoke-ems-${Date.now()}@amdash-e2e.test`;
  const password = 'SmokeTest123';
  // emailVerified: true — required for mandatory MFA's /mfa-setup screen to
  // skip straight to TOTP enrollment (see run-admin-patrol-test.mjs's fuller
  // comment on this same line).
  const user = await getAuth().createUser({ email, password, emailVerified: true });
  await db.doc(`users/${user.uid}`).set(
    { email, role: ['ems'], organizationId, firstName: 'Smoke', lastName: 'Ems' },
    { merge: true },
  );
  return { email, password, uid: user.uid };
}

async function cleanup(db, auth, smokeAccountUid) {
  await auth.deleteUser(smokeAccountUid).catch(() => {});
  await db.doc(`users/${smokeAccountUid}`).delete().catch(() => {});

  // Broad prefix sweep, not just this run's own account — an interrupted
  // run (killed process, a Test Lab run that crashed between --seed-only
  // and --teardown) otherwise orphans its account forever, since no
  // *future* run would ever know to clean up an account it didn't create
  // itself. Confirmed for real this session: accounts from days earlier
  // still sitting in Firebase Auth, because this only ever deleted the
  // one uid passed in. Same pattern admin's cleanup() already uses, and
  // the same reasoning the patient sweep below already applied to
  // patients specifically.
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (user.email?.startsWith('smoke-ems-') && user.uid !== smokeAccountUid) {
        await auth.deleteUser(user.uid).catch(() => {});
        await db.doc(`users/${user.uid}`).delete().catch(() => {});
        deletedUsers++;
      }
    }
    pageToken = page.pageToken;
  } while (pageToken);

  // Belt-and-suspenders: the test deletes its own patient as its last
  // step, but if it failed partway through (after create, before delete),
  // sweep for anything left behind so it doesn't linger in test-org.
  const patientSnap = await db
    .collection('patients')
    .where('name', '>=', 'Patrol EMS Test Patient')
    .where('name', '<', 'Patrol EMS Test Patiend')
    .get();
  for (const doc of patientSnap.docs) await doc.ref.delete();

  console.log(
    `Cleanup: removed throwaway EMS account, ${deletedUsers} other leftover EMS account(s), ` +
      `${patientSnap.size} leftover patient(s).`,
  );
}

const { seedOnly, teardown, accountJsonPath } = parseArgs(process.argv.slice(2));

const credentialPath = initFirebaseAdmin('emspatrol');
const db = getFirestore();
const auth = getAuth();

if (teardown) {
  const account = JSON.parse(fs.readFileSync(accountJsonPath, 'utf8'));
  await cleanup(db, auth, account.uid);
  fs.unlinkSync(accountJsonPath);
  if (credentialPath) fs.unlinkSync(credentialPath);
  console.log('Teardown complete.');
  process.exit(0);
}

let account;
let exitCode = 1;
try {
  account = await createSmokeEmsAccount(db);
  console.log('Created throwaway EMS account:', account.email);

  if (seedOnly) {
    fs.writeFileSync(accountJsonPath, JSON.stringify(account));
    console.log('Wrote seeded account to', accountJsonPath);
    exitCode = 0;
  } else {
    exitCode = await runPatrolTest({
      appDir: EMS_APP_DIR,
      target: 'patrol_test/ems_test.dart',
      dartDefines: { SMOKE_EMAIL: account.email, SMOKE_PASSWORD: account.password },
      device: process.env.PATROL_DEVICE || 'chrome',
    });
  }
} finally {
  // --seed-only intentionally skips cleanup — teardown happens in a later,
  // separately-invoked `--teardown` run (see the Test Lab workflows), after
  // `patrol build` + `gcloud firebase test ... run` have both used this
  // seeded state.
  if (!seedOnly && account) await cleanup(db, auth, account.uid);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

if (seedOnly) {
  console.log(exitCode === 0 ? '\n✅ Seed complete.' : '\n❌ Seed failed.');
} else {
  console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
}
process.exit(exitCode);
