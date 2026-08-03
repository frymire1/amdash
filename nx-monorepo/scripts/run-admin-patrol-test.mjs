#!/usr/bin/env node
// Self-contained runner for the admin app's Patrol e2e test — mirrors the
// pattern the earlier Playwright verification scripts used (create
// throwaway Firebase state, drive the test, tear the state back down),
// but as a permanent, reusable script instead of a one-off deleted after
// each run. Creates a fresh smoke-admin-*@amdash-e2e.test account, runs
// `patrol test`, and always cleans up (account + anything the test itself
// creates: patrol-created-* users, "Patrol Test Hospital *" hospitals)
// regardless of whether the test passed or failed.
//
// Usage: node scripts/run-admin-patrol-test.mjs
// Requires: flutter + patrol_cli on PATH (or edit FLUTTER_BIN/PATROL_BIN
// below to match your machine), a cached `firebase login` CLI session.

import { spawn } from 'node:child_process';
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..', '..');
const ADMIN_APP_DIR = path.join(REPO_ROOT, 'flutter', 'apps', 'admin');

// Adjust these if your machine's Flutter/pub-cache locations differ.
const FLUTTER_BIN = path.join(os.homedir(), 'flutter', 'bin');
const PUB_CACHE_BIN = path.join(os.homedir(), 'AppData', 'Local', 'Pub', 'Cache', 'bin');

function initFirebaseAdmin() {
  const firebaseToolsConfigPath = path.join(os.homedir(), '.config/configstore/firebase-tools.json');
  const { tokens } = JSON.parse(fs.readFileSync(firebaseToolsConfigPath, 'utf8'));
  const credential = {
    client_id: '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com',
    client_secret: 'j9iVZfS8kkCEFUPaAeJV0sAi',
    refresh_token: tokens.refresh_token,
    type: 'authorized_user',
  };
  const credentialPath = path.join(os.tmpdir(), `amdash-adminpatrol-adc-${process.pid}.json`);
  fs.writeFileSync(credentialPath, JSON.stringify(credential));
  process.env['GOOGLE_APPLICATION_CREDENTIALS'] = credentialPath;
  initializeApp({ projectId: 'amdash-dev' });
  return credentialPath;
}

async function createSmokeAdminAccount(db) {
  const orgSnap = await db.collection('organizations').where('name', '==', 'test-org').get();
  const organizationId = orgSnap.docs[0]?.id;
  if (!organizationId) throw new Error('test-org not found — seed it before running this script.');

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

function runPatrolTest(email, password) {
  return new Promise((resolve) => {
    const extraPath = [FLUTTER_BIN, PUB_CACHE_BIN, process.env.Path ?? process.env.PATH ?? ''].join(
      path.delimiter,
    );
    // Set both casings — Git Bash's inherited env has PATH (POSIX
    // convention); native Windows child-process resolution wants Path.
    const env = { ...process.env, Path: extraPath, PATH: extraPath };
    const args = [
      'test',
      '--device',
      'chrome',
      '--target',
      'patrol_test/user_flow_test.dart',
      '--dart-define',
      `SMOKE_EMAIL=${email}`,
      '--dart-define',
      `SMOKE_PASSWORD=${password}`,
    ];
    // Absolute path, not relying on PATH resolution — Node's child_process
    // spawn on Windows is unreliable about honoring a manually-constructed
    // Path/PATH env var (case-sensitivity mismatch between Git Bash's
    // POSIX-style PATH and Windows' native Path), so "patrol" alone
    // resolves inconsistently depending on what shell launched this script.
    const patrolBin = path.join(PUB_CACHE_BIN, 'patrol.bat');
    console.log('Running:', patrolBin, args.join(' '));
    const child = spawn(patrolBin, args, { cwd: ADMIN_APP_DIR, env, shell: true, stdio: 'inherit' });
    child.on('close', (code) => resolve(code ?? 1));
  });
}

const credentialPath = initFirebaseAdmin();
const db = getFirestore();
const auth = getAuth();

let account;
let exitCode = 1;
try {
  account = await createSmokeAdminAccount(db);
  console.log('Created throwaway admin account:', account.email);
  exitCode = await runPatrolTest(account.email, account.password);
} finally {
  await cleanup(db, auth, account?.uid);
  fs.unlinkSync(credentialPath);
}

console.log(exitCode === 0 ? '\n✅ Patrol test passed.' : '\n❌ Patrol test failed.');
process.exit(exitCode);
