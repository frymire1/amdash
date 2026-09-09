#!/usr/bin/env node
// Self-contained runner for the EMS app's Patrol e2e test — same pattern
// as run-admin-patrol-test.mjs, except this one signs into a *persistent*
// account rather than a fresh throwaway one. patrol_test/ems_test.dart
// itself creates, edits, and deletes its own throwaway patient through
// the app's UI, and (web only) also drives a wrong-app rejection using
// the sibling persistent physician account — see that file's own header
// comment for the full shape and why nothing here ever needs a sign-out.
//
// Why persistent, not a fresh account every run (like every other script
// in this family): merging the wrong-app-rejection scenario into this
// same session — the point of this change — needs the CRUD account to
// already be MFA-enrolled *before* this run starts, since nothing in a
// single continuous session can both enroll fresh and also resolve a
// prior scenario's own account-switch cleanly (see ems_test.dart's own
// header comment). A fresh account is never pre-enrolled, so it can't
// work here. persistent-ems@amdash-e2e.test was created once (Admin SDK)
// and MFA-enrolled once, by hand, driving the real enrollment UI locally
// (no server-side shortcut exists for TOTP — see amdash_patrol_helpers'
// completeMfaEnrollment) — its TOTP secret is stored as the
// E2E_EMS_TOTP_SECRET repo secret, read here and passed through to
// signInWithTotp, which computes a fresh valid code on every sign-in the
// same way a real authenticator app would. Never torn down between runs;
// see cleanup()'s own comment for what teardown actually still does here.
//
// Shared by both platforms this file's own scenario runs on: the default
// (no-flag) mode below drives Chrome directly (web e2e); --seed-only
// writes this same persistent account's credentials (not a freshly
// created one) to --account-json for the Android e2e job's own
// `patrol build android` step to pick up — see ci.yml's flutter-android-
// e2e job. Both platforms sign into the exact same account now, which is
// what lets ems_test.dart's own signInWithTotp call be unconditional
// rather than needing yet another platform branch.
//
// Usage:
//   node scripts/run-ems-patrol-test.mjs
//     Default: run `patrol test` against Chrome, verify the resulting
//     audit-log entries, sweep any orphaned patient debris. Used by web-e2e.
//   node scripts/run-ems-patrol-test.mjs --seed-only [--account-json=<path>]
//     Ensures org-level flags (fhirExportEnabled/auditLoggingEnabled) are
//     set, writes the persistent account's credentials to --account-json,
//     and exits 0 — no `patrol test` run, no account creation (there's
//     nothing left to create). Used ahead of `patrol build` in the
//     Firebase Test Lab (flutter-android-e2e) workflow.
//   node scripts/run-ems-patrol-test.mjs --teardown [--account-json=<path>]
//     Sweeps any orphaned patient debris left under this account — no
//     account deletion (persistent, never torn down). Used after the
//     `gcloud firebase test ... run` step in the Test Lab workflow.
// Requires: flutter + patrol_cli on PATH (or edit scripts/lib/run-patrol.mjs
// to match your machine), a cached `firebase login` CLI session (or
// GOOGLE_APPLICATION_CREDENTIALS set, e.g. in CI), and E2E_EMS_PASSWORD/
// E2E_EMS_TOTP_SECRET in the environment (repo secrets in CI).

import { getAuth } from 'firebase-admin/auth';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';
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

// See this file's own header comment for why these are fixed/persistent
// rather than generated per run.
const EMS_EMAIL = 'persistent-ems@amdash-e2e.test';
// The *other* persistent account — used only for the wrong-app-rejection
// phase inside ems_test.dart (a physician-role account attempting EMS
// sign-in), never signed into for real here.
const WRONG_APP_EMAIL = 'persistent-physician@amdash-e2e.test';
const EMS_PASSWORD = process.env.E2E_EMS_PASSWORD;
const EMS_TOTP_SECRET = process.env.E2E_EMS_TOTP_SECRET;

function parseArgs(argv) {
  const seedOnly = argv.includes('--seed-only');
  const teardown = argv.includes('--teardown');
  if (seedOnly && teardown) throw new Error('--seed-only and --teardown are mutually exclusive.');
  const accountJsonArg = argv.find((arg) => arg.startsWith('--account-json='));
  const accountJsonPath = accountJsonArg ? accountJsonArg.slice('--account-json='.length) : DEFAULT_ACCOUNT_JSON_PATH;
  return { seedOnly, teardown, accountJsonPath };
}

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
async function ensureOrgFlags(db) {
  const organizationId = await findOrganizationId(db, 'test-org');
  await db
    .doc(`organizations/${organizationId}`)
    .set({ fhirExportEnabled: true, auditLoggingEnabled: true }, { merge: true });
}

// Confirms ems_test.dart's own UI-level flow (add/edit/delete a patient,
// then complete transport + export a FHIR record) actually produced the
// audit-log entries SECURITY.md's coverage table expects for each of these
// five patient.* actions.
//
// Scoped to `since` (a timestamp captured right before this run's own
// `patrol test` started) — not just "any entry ever for this actorUid",
// which is all the pre-persistent-account version of this check needed,
// back when actorUid was a fresh uid every run. Now that the account is
// persistent, an unscoped check would trivially pass forever after the
// very first successful run, regardless of whether *this* run's own
// actions actually got logged — it would only ever prove the account had
// done this at some point in its history. Needs a composite index
// (auditLog: actorUid + action + timestamp) — see firestore.indexes.json.
//
// patient.decrypt isn't checked here — it only fires for a genuinely
// CMEK-encrypted field (see amdash_core's patient_decryption_service.dart's
// _needsDecrypt), which no current e2e flow, including this one, ever
// triggers (test-org isn't CMEK-opted-in). That's a separate, larger
// follow-up — a dedicated CMEK e2e flow — not an oversight here.
//
// Known residual gap: actorUid is shared with flutter-android-e2e's own
// run of this same file (both sign into the one persistent EMS account —
// see this file's own header comment for why that's safe here, unlike
// physician's equivalent), and that job runs concurrently with this one,
// not sequentially. If both happen to be mid-flight at once, an entry
// this check matches could technically be the *other* job's own action
// rather than this run's, which would mask a genuine regression in
// exactly one of them for the same action type at the same time — a
// narrow, compound failure mode (needs real overlap *and* a real bug in
// only one leg), not fixed here. Disambiguating fully would mean matching
// on the specific patient id too, which would need threading
// debugLastUploadedPatientId through for both of this test's own patients,
// not just the FHIR-export one it already captures — a real improvement,
// just not done in this pass.
async function verifyPatientAuditEntries(db, actorUid, since) {
  const actions = ['patient.create', 'patient.update', 'patient.delete', 'patient.complete', 'patient.fhirExport'];
  for (const action of actions) {
    const snap = await db
      .collection('auditLog')
      .where('actorUid', '==', actorUid)
      .where('action', '==', action)
      .where('timestamp', '>', since)
      .limit(1)
      .get();
    if (snap.empty) {
      throw new Error(
        `No ${action} audit-log entry found for this run's EMS account (${actorUid}) since ${since.toDate().toISOString()}.`,
      );
    }
  }
  console.log(`✅ Confirmed audit-log entries for: ${actions.join(', ')}.`);
}

// Backstop for a patient left behind by a genuinely crashed run (process
// killed outright, not just an assertion failure — ems_test.dart's own
// try/finally blocks already handle the normal failure case). The old
// version of this swept by "owner account no longer exists", which can
// never fire now that the owning account (persistent-ems) is never
// deleted — age-guarded directly off the patient document's own
// `submittedAt` server timestamp instead. Not a name-prefix match: `name`
// is encrypted client-side by the real upload flow this test's patients
// go through (see patient_upload_service.dart/encryptPatientFields), so a
// plaintext query against it can never match — confirmed for real in an
// earlier version of this sweep, which relied on exactly that and quietly
// matched nothing for months.
const ORPHAN_SWEEP_AGE_MS = 20 * 60 * 1000; // 20 minutes — see isOldEnoughToSweep's own reasoning.

async function sweepOrphanedPatients(db, emsUid) {
  const cutoff = Timestamp.fromMillis(Date.now() - ORPHAN_SWEEP_AGE_MS);
  const snap = await db
    .collection('patients')
    .where('createdBy', '==', emsUid)
    .where('submittedAt', '<', cutoff)
    .get();
  let deleted = 0;
  for (const doc of snap.docs) {
    await db.recursiveDelete(doc.ref);
    deleted++;
  }
  console.log(`Cleanup: removed ${deleted} orphaned patient(s) older than ${ORPHAN_SWEEP_AGE_MS / 60000} minutes.`);
}

const { seedOnly, teardown, accountJsonPath } = parseArgs(process.argv.slice(2));

// Teardown only ever sweeps by uid (looked up fresh below) — it never
// needs the password/secret, so it's the one mode that can run without
// them set. --seed-only and the default (web) mode both write/use the
// real password+secret, so they still fail fast here rather than writing
// a JSON file with undefined fields, or an empty dart-define, that would
// only surface as a confusing failure several steps later.
if (!teardown && (!EMS_PASSWORD || !EMS_TOTP_SECRET)) {
  console.error('E2E_EMS_PASSWORD and E2E_EMS_TOTP_SECRET must both be set in the environment.');
  process.exit(1);
}

const credentialPath = initFirebaseAdmin('emspatrol');
const db = getFirestore();
const auth = getAuth();
const emsUid = (await auth.getUserByEmail(EMS_EMAIL)).uid;

if (teardown) {
  await sweepOrphanedPatients(db, emsUid);
  if (fs.existsSync(accountJsonPath)) fs.unlinkSync(accountJsonPath);
  if (credentialPath) fs.unlinkSync(credentialPath);
  console.log('Teardown complete.');
  process.exit(0);
}

if (seedOnly) {
  await ensureOrgFlags(db);
  fs.writeFileSync(
    accountJsonPath,
    JSON.stringify({ email: EMS_EMAIL, password: EMS_PASSWORD, totpSecret: EMS_TOTP_SECRET, uid: emsUid }),
  );
  console.log('Wrote persistent EMS account to', accountJsonPath);
  if (credentialPath) fs.unlinkSync(credentialPath);
  process.exit(0);
}

let exitCode = 1;
try {
  await ensureOrgFlags(db);
  // Captured right before the real test run starts — verifyPatientAuditEntries
  // below only accepts entries stamped after this, so a stale entry from
  // some earlier run of this same persistent account can never
  // false-positive this check.
  const since = Timestamp.now();

  exitCode = await runPatrolTest({
    appDir: EMS_APP_DIR,
    device: process.env.PATROL_DEVICE || 'chrome',
    // ems_test.dart never grants geolocation (it deliberately leaves live
    // tracking off) — but LocationTrackingSection.initState() still calls
    // Geolocator.getCurrentPosition() unconditionally on every mount of
    // the upload/edit form regardless. With no permission decision at
    // all, the browser leaves the request in "prompt" limbo indefinitely
    // (no UI to click through in headless CI), so it only ever resolves
    // via that call's own internal 12s Dart-side timeout — a real race
    // window against Patrol's own 10s hit-test timeout, confirmed via a
    // real GHA "Found 0 widgets with type TextField" right around that
    // ~12s mark. Explicitly denying (empty permissions array, not
    // omitted) makes the browser reject the request immediately instead,
    // removing the race entirely.
    webPermissions: [],
    target: 'patrol_test/ems_test.dart',
    dartDefines: {
      SMOKE_EMAIL: EMS_EMAIL,
      SMOKE_PASSWORD: EMS_PASSWORD,
      SMOKE_TOTP_SECRET: EMS_TOTP_SECRET,
      WRONG_APP_EMAIL: WRONG_APP_EMAIL,
    },
  });

  if (exitCode === 0) {
    try {
      await verifyPatientAuditEntries(db, emsUid, since);
    } catch (error) {
      console.error(error.message);
      exitCode = 1;
    }
  } else {
    console.log('\n❌ Patrol test failed — skipping the audit-entry checks (nothing meaningful to verify).');
  }
} finally {
  await sweepOrphanedPatients(db, emsUid);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
