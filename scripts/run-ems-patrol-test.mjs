#!/usr/bin/env node
// Self-contained runner for the EMS app's Patrol e2e test — same pattern
// as run-admin-patrol-test.mjs. Simpler than physician's runner: the test
// itself creates, edits, and deletes its own throwaway patient entirely
// through the app's UI (see patrol_test/ems_test.dart), so
// this script only needs to create/delete the throwaway EMS account. On the
// self-contained (non --seed-only/--teardown) path, it also verifies the
// resulting patient.* audit-log entries directly via the Admin SDK — see
// verifyPatientAuditEntries's own comment. Wired into .github/workflows/
// ci.yml's e2e job — not a local-only dev tool.
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
import { findOrganizationId, initFirebaseAdmin, isOldEnoughToSweep } from './lib/firebase-admin-cli.mjs';
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
  // FHIR export is opt-in per org — ems_test.dart's own flow exercises the
  // export-on-complete-transport prompt, so make sure it's reachable
  // regardless of whatever this shared fixture's last state was. Safe to
  // set unconditionally: it only ever adds a new opt-in prompt, never
  // changes any other existing behavior this or any other test relies on.
  // auditLoggingEnabled likewise — verifyPatientAuditEntries below needs
  // the patient.* actions this test triggers to actually get logged
  // (logAudit silently skips GATED_ACTIONS when an org has explicitly
  // turned this off — see audit.ts), regardless of whatever some other
  // concurrently-running or earlier test last left this shared org's
  // toggle set to.
  await db.doc(`organizations/${organizationId}`).set({ fhirExportEnabled: true, auditLoggingEnabled: true }, { merge: true });
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

// Confirms ems_test.dart's own UI-level flow (add/edit/delete a patient,
// then complete transport + export a FHIR record) actually produced the
// audit-log entries SECURITY.md's coverage table expects for each of these
// five patient.* actions — previously listed there as "🔜 planned": the
// actions themselves already fired on every green run, nothing had ever
// checked the resulting audit rows actually existed.
//
// Keyed on actorUid (this run's own freshly-created smoke account), not
// target/details — the two patients this test creates never surface their
// Firestore-generated ids back to this script, but actorUid is unique to
// this run regardless (a fresh account every time), so it's an
// unambiguous, race-safe match even with sibling e2e jobs writing to this
// same shared test-org concurrently (see firebase-admin-cli.mjs's own
// comment on that risk).
//
// patient.decrypt isn't checked here — it only fires for a genuinely
// CMEK-encrypted field (see amdash_core's patient_decryption_service.dart's
// _needsDecrypt), which no current e2e flow, including this one, ever
// triggers (test-org isn't CMEK-opted-in). That's a separate, larger
// follow-up — a dedicated CMEK e2e flow — not an oversight here.
async function verifyPatientAuditEntries(db, actorUid) {
  const actions = ['patient.create', 'patient.update', 'patient.delete', 'patient.complete', 'patient.fhirExport'];
  for (const action of actions) {
    const snap = await db.collection('auditLog').where('actorUid', '==', actorUid).where('action', '==', action).limit(1).get();
    if (snap.empty) {
      throw new Error(`No ${action} audit-log entry found for this run's EMS account (${actorUid}).`);
    }
  }
  console.log(`✅ Confirmed audit-log entries for: ${actions.join(', ')}.`);
}

async function cleanup(db, auth, smokeAccountUids) {
  const ownUids = new Set(Array.isArray(smokeAccountUids) ? smokeAccountUids : [smokeAccountUids]);
  for (const uid of ownUids) {
    await auth.deleteUser(uid).catch(() => {});
    await db.doc(`users/${uid}`).delete().catch(() => {});
  }

  // Broad prefix sweep, not just this run's own account(s) — an
  // interrupted run (killed process, a Test Lab run that crashed between
  // --seed-only and --teardown) otherwise orphans its account forever,
  // since no *future* run would ever know to clean up an account it
  // didn't create itself. Confirmed for real this session: accounts from
  // days earlier still sitting in Firebase Auth, because this only ever
  // deleted the one uid passed in. Same pattern admin's cleanup() already
  // uses, and the same reasoning the patient sweep below already applied
  // to patients specifically. Age-guarded (isOldEnoughToSweep) on top of
  // that — a broad sweep with no age check can delete a
  // concurrently-running sibling job's still-in-use account (confirmed
  // for real: see that function's own comment).
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (user.email?.startsWith('smoke-ems-') && !ownUids.has(user.uid) && isOldEnoughToSweep(user.email)) {
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
  //
  // A name/destination-based query (what an earlier version of this
  // function used) is a dead end: `name` is encrypted client-side by the
  // real upload flow this test's patient goes through (see
  // patient_upload_service.dart/encryptPatientFields), so a plaintext
  // range query against it can never match, and this test's patient sets
  // no `destination` either — confirmed for real, several genuinely
  // leftover "Patrol EMS Test Patient..." documents accumulated in
  // test-org from failed runs while that query reported 0 every time.
  //
  // `createdBy` is the reliable signal instead: every patient write stamps
  // it with the creating user's uid (patient_upload_service.dart's own
  // doc comment), in plaintext, unconditionally. A patient whose
  // `createdBy` uid no longer resolves to a real Auth user can only be one
  // this script's own account-sweep already deleted above — a genuine
  // person's account is never deleted out from under their own patients
  // in normal use, so "owner doesn't exist" is an unambiguous signal this
  // is orphaned test debris, not a guess. Also safe against sibling jobs:
  // a concurrently-running job's account still exists until *that* job's
  // own cleanup deletes it, so this can never catch a patient still
  // legitimately in use elsewhere — no separate age guard needed the way
  // the prefix-based account sweep above requires one.
  const organizationId = await findOrganizationId(db, 'test-org');
  const testOrgPatientsSnap = await db.collection('patients').where('organizationId', '==', organizationId).get();
  const ownerUids = [...new Set(testOrgPatientsSnap.docs.map((doc) => doc.data().createdBy).filter(Boolean))];
  const existingUids = new Set();
  for (let i = 0; i < ownerUids.length; i += 100) {
    const batch = ownerUids.slice(i, i + 100).map((uid) => ({ uid }));
    const { users } = await auth.getUsers(batch);
    for (const user of users) existingUids.add(user.uid);
  }
  let deletedPatients = 0;
  for (const doc of testOrgPatientsSnap.docs) {
    const owner = doc.data().createdBy;
    if (owner && !existingUids.has(owner)) {
      await doc.ref.delete();
      deletedPatients++;
    }
  }

  console.log(
    `Cleanup: removed ${ownUids.size} throwaway EMS account(s), ${deletedUsers} other leftover EMS account(s), ` +
      `${deletedPatients} leftover patient(s) with a deleted owner.`,
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
    // Both of ems_test.dart's own phases (add/edit/delete a patient, then
    // complete transport + export FHIR) run in this one `patrol test`
    // process, inside one `patrolTest` block, sharing this one account and
    // its one MFA enrollment — see that file's own header comment for why
    // (used to be two separate patrol test files/processes/accounts
    // specifically to route around a cross-process MFA limitation; one
    // continuous patrolTest block never hits that limitation in the first
    // place, since nothing ever reloads mid-test to lose the session).
    exitCode = await runPatrolTest({
      appDir: EMS_APP_DIR,
      device: process.env.PATROL_DEVICE || 'chrome',
      // ems_test.dart never grants geolocation (it deliberately leaves
      // live tracking off in both phases) — but
      // LocationTrackingSection.initState() still calls
      // Geolocator.getCurrentPosition() unconditionally on every mount of
      // the upload/edit form regardless. With no permission decision at
      // all, the browser leaves the request in "prompt" limbo
      // indefinitely (no UI to click through in headless CI), so it only
      // ever resolves via that call's own internal 12s Dart-side timeout
      // — a real race window against Patrol's own 10s hit-test timeout,
      // confirmed via a real GHA "Found 0 widgets with type TextField"
      // right around that ~12s mark. Explicitly denying (empty
      // permissions array, not omitted) makes the browser reject the
      // request immediately instead, removing the race entirely.
      webPermissions: [],
      target: 'patrol_test/ems_test.dart',
      dartDefines: { SMOKE_EMAIL: account.email, SMOKE_PASSWORD: account.password },
    });

    if (exitCode === 0) {
      try {
        await verifyPatientAuditEntries(db, account.uid);
      } catch (error) {
        console.error(error.message);
        exitCode = 1;
      }
    } else {
      console.log('\n❌ Patrol test failed — skipping the audit-entry checks (nothing meaningful to verify).');
    }
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
