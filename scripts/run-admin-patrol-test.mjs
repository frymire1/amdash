#!/usr/bin/env node
// Self-contained runner for the admin app's own user-management Patrol
// e2e test — mirrors the pattern the earlier Playwright verification
// scripts used (create throwaway Firebase state, drive the test, tear the
// state back down), but as a permanent, reusable script instead of a
// one-off deleted after each run. Creates a fresh smoke-admin-*
// @amdash-e2e.test account, runs `patrol test`, and always cleans up
// (account + anything the test itself creates: patrol-created-* users,
// "Patrol Test Hospital *" hospitals) regardless of whether the test
// passed or failed. Wired into .github/workflows/ci.yml's e2e job — not a
// local-only dev tool.
//
// organization_management_test.dart used to run here too, right after
// this one — split into its own script (run-admin-org-management-e2e.mjs)
// and parallel CI job instead, the same pattern already proven for
// physician's/EMS's own wrong-app legs: it genuinely needs a different
// account (a super-admin with no organization membership at all, not the
// regular org-scoped admin this test uses — see that script's own header
// comment), which would need a sign-out to reach from here, and
// AuthService.signOut() (amdash_core) deliberately forces a full page
// reload on web that kills a still-running Patrol test — not something to
// route around. Splitting into two parallel jobs gets the same real
// build-time win (this job no longer pays for two sequential builds) with
// none of that risk.
//
// Written in Node/JS rather than Dart because it needs the Firebase
// *Admin* SDK (elevated, server-side — creates/deletes real Auth users and
// bypasses Firestore rules) to seed and tear down data around the actual
// Dart-side Patrol test; scripts/ already has Node + firebase-admin set
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
import { findOrganizationId, initFirebaseAdmin, isOldEnoughToSweep } from './lib/firebase-admin-cli.mjs';
import { runPatrolTest } from './lib/run-patrol.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const ADMIN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'admin');

async function createSmokeAdminAccount(db) {
  const organizationId = await findOrganizationId(db, 'test-org');
  const email = `smoke-admin-${Date.now()}@amdash-e2e.test`;
  const password = 'SmokeTest123';
  // emailVerified: true is required here, not just convenient — mandatory
  // MFA (AppRouteGuard's requireMfa tier) blocks a never-enrolled account
  // behind /mfa-setup immediately after sign-in, and that screen itself
  // requires a verified email before it'll even show the TOTP enrollment
  // step. The test drives the real enrollment (see user_flow_test.dart's
  // completeMfaEnrollment), so this only needs to skip straight to that.
  const user = await getAuth().createUser({ email, password, emailVerified: true });
  await db.doc(`users/${user.uid}`).set(
    { email, role: ['admin'], organizationId, firstName: 'Smoke', lastName: 'Admin' },
    { merge: true },
  );
  return { email, password, uid: user.uid };
}

async function cleanup(db, auth, accountUid) {
  // Age-guarded for every account/hospital other than this run's own
  // (always safe, always deleted regardless of age) — see
  // isOldEnoughToSweep's own comment: without this, a broad sweep here
  // can delete a concurrently-running sibling job's still-in-use state.
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (
        user.uid === accountUid ||
        (user.email &&
          (user.email.startsWith('smoke-admin-') || user.email.startsWith('patrol-created-')) &&
          isOldEnoughToSweep(user.email))
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
  let deletedHospitals = 0;
  for (const doc of hospSnap.docs) {
    if (isOldEnoughToSweep(doc.data().name)) {
      await doc.ref.delete();
      deletedHospitals++;
    }
  }

  console.log(`Cleanup: removed ${deletedUsers} throwaway user(s), ${deletedHospitals} leftover hospital(s).`);
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
