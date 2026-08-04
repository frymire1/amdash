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
// nx-monorepo already has that set up.
//
// Usage: node scripts/run-ems-patrol-test.mjs
// Requires: flutter + patrol_cli on PATH (or edit scripts/lib/run-patrol.mjs
// to match your machine), a cached `firebase login` CLI session (or
// GOOGLE_APPLICATION_CREDENTIALS set, e.g. in CI).

import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { findOrganizationId, initFirebaseAdmin } from './lib/firebase-admin-cli.mjs';
import { runPatrolTest } from './lib/run-patrol.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..', '..');
const EMS_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'ems');

async function createSmokeEmsAccount(db) {
  const organizationId = await findOrganizationId(db, 'test-org');
  const email = `smoke-ems-${Date.now()}@amdash-e2e.test`;
  const password = 'SmokeTest123';
  const user = await getAuth().createUser({ email, password });
  await db.doc(`users/${user.uid}`).set(
    { email, role: ['ems'], organizationId, firstName: 'Smoke', lastName: 'Ems' },
    { merge: true },
  );
  return { email, password, uid: user.uid };
}

async function cleanup(db, auth, smokeAccountUid) {
  await auth.deleteUser(smokeAccountUid).catch(() => {});
  await db.doc(`users/${smokeAccountUid}`).delete().catch(() => {});

  // Belt-and-suspenders: the test deletes its own patient as its last
  // step, but if it failed partway through (after create, before delete),
  // sweep for anything left behind so it doesn't linger in test-org.
  const patientSnap = await db
    .collection('patients')
    .where('name', '>=', 'Patrol EMS Test Patient')
    .where('name', '<', 'Patrol EMS Test Patiend')
    .get();
  for (const doc of patientSnap.docs) await doc.ref.delete();

  console.log(`Cleanup: removed throwaway EMS account, ${patientSnap.size} leftover patient(s).`);
}

const credentialPath = initFirebaseAdmin('emspatrol');
const db = getFirestore();
const auth = getAuth();

let account;
let exitCode = 1;
try {
  account = await createSmokeEmsAccount(db);
  console.log('Created throwaway EMS account:', account.email);
  exitCode = await runPatrolTest({
    appDir: EMS_APP_DIR,
    target: 'patrol_test/ems_test.dart',
    dartDefines: { SMOKE_EMAIL: account.email, SMOKE_PASSWORD: account.password },
  });
} finally {
  if (account) await cleanup(db, auth, account.uid);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
