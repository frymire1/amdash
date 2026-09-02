#!/usr/bin/env node
// Self-contained runner for the admin app's own organization-creation
// Patrol e2e test — split out of run-admin-patrol-test.mjs into its own
// script and parallel CI job, the same pattern already proven for
// physician's/EMS's own wrong-app legs. See run-admin-patrol-test.mjs's
// own header comment for why: organization_management_test.dart
// genuinely needs a different account than user_flow_test.dart (a
// super-admin with no organization membership at all — see
// createSmokeSuperAdminAccount's own comment below — not the regular
// org-scoped admin the other test uses), and getting there from an
// already-signed-in session would need a sign-out that
// AuthService.signOut() (amdash_core) turns into a full page reload on
// web, which kills a still-running Patrol test outright. Splitting into
// two independent scripts/jobs sidesteps that entirely — no mid-session
// account transition needed at all.
//
// Creates a fresh smoke-superadmin-*@amdash-e2e.test account, runs
// `patrol test`, verifies the resulting organization.create audit-log
// entry directly via the Admin SDK (see verifyOrganizationCreateAuditEntry's
// own comment for why that can't be checked through the app's own UI),
// and always cleans up (account + the org it created + anything the test
// itself creates: patrol-org-admin-* users) regardless of whether the
// test passed or failed. Wired into .github/workflows/ci.yml's e2e job —
// not a local-only dev tool.
//
// Usage: node scripts/run-admin-org-management-e2e.mjs
// Requires: flutter + patrol_cli on PATH (or edit FLUTTER_BIN/PATROL_BIN in
// scripts/lib/run-patrol.mjs to match your machine), a cached `firebase
// login` CLI session (or GOOGLE_APPLICATION_CREDENTIALS set, e.g. in CI).

import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { initFirebaseAdmin, isOldEnoughToSweep } from './lib/firebase-admin-cli.mjs';
import { runPatrolTest } from './lib/run-patrol.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const ADMIN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'admin');

// No organizationId — a real super-admin has none of their own (see
// createOrganization's own comment in functions/src/admin.ts); requireAdmin
// would reject this account for every *other* admin.ts callable, which is
// exactly right, since organization_management_test.dart only ever
// exercises createOrganization, the one callable gated on 'super-admin'
// specifically rather than requireAdmin.
async function createSmokeSuperAdminAccount() {
  const email = `smoke-superadmin-${Date.now()}@amdash-e2e.test`;
  const password = 'SmokeTest123';
  const user = await getAuth().createUser({ email, password, emailVerified: true });
  await getFirestore().doc(`users/${user.uid}`).set(
    { email, role: ['super-admin'], firstName: 'Smoke', lastName: 'SuperAdmin' },
    { merge: true },
  );
  return { email, password, uid: user.uid };
}

// organization.create's own audit entry can't be verified through the app
// UI at all — see organization_management_test.dart's own header comment
// for why (a pure super-admin fails listAuditLog's requireAdmin check, and
// the newly-created org's own first admin would need a full first-login
// flow just to check one row). Reads it directly via the Admin SDK instead,
// bypassing that UI limitation rather than building a second onboarding
// flow just for this one check.
async function verifyOrganizationCreateAuditEntry(db, organizationName) {
  const snap = await db
    .collection('auditLog')
    .where('action', '==', 'organization.create')
    .where('details.organizationName', '==', organizationName)
    .limit(1)
    .get();
  if (snap.empty) {
    throw new Error(`No organization.create audit entry found for "${organizationName}".`);
  }
  console.log(`✅ Confirmed organization.create audit entry for "${organizationName}".`);
}

async function cleanup(db, auth, accountUid) {
  // Age-guarded for every account/organization other than this run's own
  // (always safe, always deleted regardless of age) — see
  // isOldEnoughToSweep's own comment: without this, a broad sweep here
  // can delete a concurrently-running sibling job's still-in-use state.
  // patrol-org-admin-* is this test's own creation (the new org's first
  // admin, atomically created alongside it).
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (
        user.uid === accountUid ||
        (user.email &&
          (user.email.startsWith('smoke-superadmin-') || user.email.startsWith('patrol-org-admin-')) &&
          isOldEnoughToSweep(user.email))
      ) {
        await auth.deleteUser(user.uid);
        await db.doc(`users/${user.uid}`).delete().catch(() => {});
        deletedUsers++;
      }
    }
    pageToken = page.pageToken;
  } while (pageToken);

  const orgSnap = await db
    .collection('organizations')
    .where('name', '>=', 'Patrol Test Org')
    .where('name', '<', 'Patrol Test Orh')
    .get();
  let deletedOrgs = 0;
  for (const doc of orgSnap.docs) {
    if (isOldEnoughToSweep(doc.data().name)) {
      await doc.ref.delete();
      deletedOrgs++;
    }
  }

  console.log(`Cleanup: removed ${deletedUsers} throwaway user(s), ${deletedOrgs} leftover organization(s).`);
}

const credentialPath = initFirebaseAdmin('adminorgmanagement');
const db = getFirestore();
const auth = getAuth();

let superAdminAccount;
let exitCode = 1;
try {
  superAdminAccount = await createSmokeSuperAdminAccount();
  console.log('Created throwaway super-admin account:', superAdminAccount.email);
  const organizationName = `Patrol Test Org ${Date.now()}`;

  const orgExitCode = await runPatrolTest({
    appDir: ADMIN_APP_DIR,
    target: 'patrol_test/organization_management_test.dart',
    dartDefines: {
      SMOKE_EMAIL: superAdminAccount.email,
      SMOKE_PASSWORD: superAdminAccount.password,
      SMOKE_ORG_NAME: organizationName,
    },
  });

  if (orgExitCode !== 0) {
    console.log('\n❌ Organization creation failed — skipping the audit-entry check (nothing to verify).');
    exitCode = orgExitCode;
  } else {
    try {
      await verifyOrganizationCreateAuditEntry(db, organizationName);
      exitCode = 0;
    } catch (error) {
      console.error(error.message);
      exitCode = 1;
    }
  }
} finally {
  await cleanup(db, auth, superAdminAccount?.uid);
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
