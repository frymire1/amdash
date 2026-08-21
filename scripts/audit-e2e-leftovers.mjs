#!/usr/bin/env node
// Manual utility (not wired into CI) — lists every Auth user, hospital,
// and patient that looks like e2e test debris, across every prefix
// convention used by the run-*-patrol-test.mjs / run-patient-flow-e2e.mjs
// scripts. Each of those scripts' own cleanup() now self-heals this on
// every run (a broad prefix sweep, not just the one account it created —
// see their own comments), so this is for a quick manual sanity check
// between runs, not a required step. Read-only — see
// cleanup-e2e-leftovers.mjs for the version that actually deletes.
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { initFirebaseAdmin } from './lib/firebase-admin-cli.mjs';

const credentialPath = initFirebaseAdmin('audit');
const db = getFirestore();
const auth = getAuth();

const TEST_EMAIL_DOMAIN = '@amdash-e2e.test';

console.log('=== Auth users with an @amdash-e2e.test email ===');
let userCount = 0;
let pageToken;
do {
  const page = await auth.listUsers(1000, pageToken);
  for (const user of page.users) {
    if (user.email?.endsWith(TEST_EMAIL_DOMAIN)) {
      console.log(`${user.uid}  ${user.email}  created=${user.metadata.creationTime}`);
      userCount++;
    }
  }
  pageToken = page.pageToken;
} while (pageToken);
console.log(`Total: ${userCount}\n`);

console.log('=== Hospitals with a "Patrol"-prefixed name ===');
const hospSnap = await db.collection('hospitals').where('name', '>=', 'Patrol').where('name', '<', 'Patrom').get();
for (const doc of hospSnap.docs) {
  console.log(`${doc.id}  ${doc.data().name}`);
}
console.log(`Total: ${hospSnap.size}\n`);

console.log('=== Patients with a "Patrol"-prefixed name ===');
const patientSnap = await db.collection('patients').where('name', '>=', 'Patrol').where('name', '<', 'Patrom').get();
for (const doc of patientSnap.docs) {
  console.log(`${doc.id}  ${doc.data().name}  status=${doc.data().status}`);
}
console.log(`Total: ${patientSnap.size}\n`);

if (credentialPath) {
  const fs = await import('node:fs');
  fs.unlinkSync(credentialPath);
}
