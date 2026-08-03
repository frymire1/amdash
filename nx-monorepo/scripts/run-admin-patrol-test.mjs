#!/usr/bin/env node
// Self-contained runner for the admin app's Patrol e2e test — mirrors the
// pattern the earlier Playwright verification scripts used (create
// throwaway Firebase state, drive the test, tear the state back down),
// but as a permanent, reusable script instead of a one-off deleted after
// each run. Creates a fresh smoke-admin-*@amdash-e2e.test account, runs
// `patrol test`, and always cleans up (account + anything the test itself
// creates: patrol-created-* users, "Patrol Test Hospital *" hospitals)
// regardless of whether the test passed or failed. Wired into
// .github/workflows/ci.yml's e2e job — not a local-only dev tool.
//
// Written in Node/JS rather than Dart because it needs the Firebase
// *Admin* SDK (elevated, server-side — creates/deletes real Auth users and
// bypasses Firestore rules) to seed and tear down data around the actual
// Dart-side Patrol test; nx-monorepo already has Node + firebase-admin set
// up for exactly this, reusing the same pattern the old Playwright e2e
// suites used before physician/ems/admin moved to Flutter.
//
// Usage: node scripts/run-admin-patrol-test.mjs
// Requires: flutter + patrol_cli on PATH (or edit FLUTTER_BIN/PATROL_BIN in
// scripts/lib/run-patrol.mjs to match your machine), a cached `firebase
// login` CLI session (or GOOGLE_APPLICATION_CREDENTIALS set, e.g. in CI).

import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { findOrganizationId, initFirebaseAdmin } from './lib/firebase-admin-cli.mjs';
import { runPatrolTest } from './lib/run-patrol.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..', '..');
const ADMIN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'admin');

async function createSmokeAdminAccount(db) {
  const organizationId = await findOrganizationId(db, 'test-org');
  const email = `smoke-admin-${Date.now()}@amdash-e2e.test`;
  const password = 'SmokeTest123';
  const user = await getAuth().createUser({ email, password });
  await db.doc(`users/${user.uid}`).set(
    { email, role: ['admin'], organizationId, firstName: 'Smoke', lastName: 'Admin' },
    { merge: true },
  );
  return { email, password, uid: user.uid };
}

async function cleanup(db, auth, smokeAccountUid) {
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (
        user.uid === smokeAccountUid ||
        (user.email && (user.email.startsWith('smoke-admin-') || user.email.startsWith('patrol-created-')))
      ) {
        await auth.deleteUser(user.uid);
        await db.doc(`users/${user.uid}`).delete().catch(() => {});
        deletedUsers++;
      }
    }
    pageToken = page.pageToken;
  } while (pageToken);

  const hospSnap = await db
    .collection('hospitals')
    .where('name', '>=', 'Patrol Test Hospital')
    .where('name', '<', 'Patrol Test Hospitc')
    .get();
  for (const doc of hospSnap.docs) await doc.ref.delete();

  console.log(`Cleanup: removed ${deletedUsers} throwaway user(s), ${hospSnap.size} leftover hospital(s).`);
}

const credentialPath = initFirebaseAdmin('adminpatrol');
const db = getFirestore();
const auth = getAuth();

let account;
let exitCode = 1;
try {
  account = await createSmokeAdminAccount(db);
  console.log('Created throwaway admin account:', account.email);
  exitCode = await runPatrolTest({
    appDir: ADMIN_APP_DIR,
    target: 'patrol_test/user_flow_test.dart',
    dartDefines: { SMOKE_EMAIL: account.email, SMOKE_PASSWORD: account.password },
  });
} finally {
  await cleanup(db, auth, account?.uid);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
