#!/usr/bin/env node
// Manual utility (not wired into CI) — deletes everything
// audit-e2e-leftovers.mjs lists. The orchestrator scripts now self-heal
// this going forward via a broad prefix sweep in their own cleanup(), so
// this is only needed for debris orphaned by an interruption that
// happened *before* a next run of the relevant script (which would have
// swept it automatically) — e.g. right after setting this up for the
// first time, or a long gap before the next real run.
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { initFirebaseAdmin } from './lib/firebase-admin-cli.mjs';

const credentialPath = initFirebaseAdmin('cleanup');
const db = getFirestore();
const auth = getAuth();

const TEST_EMAIL_DOMAIN = '@amdash-e2e.test';

let deletedUsers = 0;
let pageToken;
do {
  const page = await auth.listUsers(1000, pageToken);
  for (const user of page.users) {
    if (user.email?.endsWith(TEST_EMAIL_DOMAIN)) {
      await auth.deleteUser(user.uid).catch(() => {});
      await db.doc(`users/${user.uid}`).delete().catch(() => {});
      console.log(`Deleted user: ${user.email}`);
      deletedUsers++;
    }
  }
  pageToken = page.pageToken;
} while (pageToken);

const hospSnap = await db.collection('hospitals').where('name', '>=', 'Patrol').where('name', '<', 'Patrom').get();
for (const doc of hospSnap.docs) {
  console.log(`Deleted hospital: ${doc.data().name}`);
  await doc.ref.delete();
}

// See audit-e2e-leftovers.mjs's matching comment: `name` is encrypted for
// any patient that went through a real app upload flow, so a plaintext
// range query against it only ever catches Admin-SDK-seeded patients
// (physician's). `destination` stays plaintext and catches the rest,
// except ems_test.dart's own patient (sets no destination at all).
const [byName, byDestination] = await Promise.all([
  db.collection('patients').where('name', '>=', 'Patrol').where('name', '<', 'Patrom').get(),
  db.collection('patients').where('destination', '>=', 'Patrol').where('destination', '<', 'Patrom').get(),
]);
const patientDocs = new Map([...byName.docs, ...byDestination.docs].map((doc) => [doc.id, doc]));
for (const doc of patientDocs.values()) {
  console.log(`Deleted patient: destination=${doc.data().destination}`);
  await db.recursiveDelete(doc.ref);
}

console.log(`\nDone. Removed ${deletedUsers} user(s), ${hospSnap.size} hospital(s), ${patientDocs.size} patient(s).`);

if (credentialPath) {
  const fs = await import('node:fs');
  fs.unlinkSync(credentialPath);
}
