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

async function cleanup(db, auth, smokeAccountUids) {
  // Age-guarded for every account/hospital/organization other than this
  // run's own (always safe, always deleted regardless of age) — see
  // isOldEnoughToSweep's own comment: without this, a broad sweep here
  // can delete a concurrently-running sibling job's still-in-use state.
  // patrol-org-admin-* is organization_management_test.dart's own
  // creation (the new org's first admin, atomically created alongside
  // it) — swept the same way patrol-created-* (user_flow_test.dart's own
  // user) already was.
  let deletedUsers = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const user of page.users) {
      if (
        smokeAccountUids.includes(user.uid) ||
        (user.email &&
          (user.email.startsWith('smoke-admin-') ||
            user.email.startsWith('smoke-superadmin-') ||
            user.email.startsWith('patrol-created-') ||
            user.email.startsWith('patrol-org-admin-')) &&
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

  console.log(
    `Cleanup: removed ${deletedUsers} throwaway user(s), ${deletedHospitals} leftover hospital(s), ` +
      `${deletedOrgs} leftover organization(s).`,
  );
}

const credentialPath = initFirebaseAdmin('adminpatrol');
const db = getFirestore();
const auth = getAuth();

let account;
let superAdminAccount;
let exitCode = 1;
try {
  account = await createSmokeAdminAccount(db);
  console.log('Created throwaway admin account:', account.email);
  exitCode = await runPatrolTest({
    appDir: ADMIN_APP_DIR,
    target: 'patrol_test/user_flow_test.dart',
    dartDefines: { SMOKE_EMAIL: account.email, SMOKE_PASSWORD: account.password },
  });

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
  let auditExitCode = 0;
  if (orgExitCode === 0) {
    try {
      await verifyOrganizationCreateAuditEntry(db, organizationName);
    } catch (error) {
      console.error(error.message);
      auditExitCode = 1;
    }
  } else {
    console.log('\n❌ Organization creation failed — skipping the audit-entry check (nothing to verify).');
  }
  if (exitCode === 0) exitCode = orgExitCode !== 0 ? orgExitCode : auditExitCode;
} finally {
  await cleanup(db, auth, [account?.uid, superAdminAccount?.uid].filter(Boolean));
  if (credentialPath) fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
