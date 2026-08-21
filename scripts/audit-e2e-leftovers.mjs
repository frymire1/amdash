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

// `name` is encrypted client-side for any patient created through a real
// app upload flow (see patient_upload_service.dart/encryptPatientFields) —
// a plaintext range query against it can only ever match a patient a
// script wrote directly via the Admin SDK (bypassing the app entirely, as
// run-physician-patrol-test.mjs's seed does). It silently matches nothing
// for EMS-app-uploaded patients (patient_upload_flow_test.dart,
// ems_test.dart) — confirmed for real: this query alone reported zero
// results while the Playwright accessibility snapshot from a failing CI
// run showed several genuinely leftover "Patrol Flow Test Patient..."
// documents. `destination` isn't PII (needed for physician's own
// destination filter) and stays plaintext, so it's used as a second,
// reliable signal for patients that went through the real upload flow
// with a distinctively-named test hospital — this still can't see
// ems_test.dart's own patient, which sets no destination at all; that one
// relies on its own explicit delete step at the end of the test.
console.log('=== Patients with a "Patrol"-prefixed name or destination ===');
const [byName, byDestination] = await Promise.all([
  db.collection('patients').where('name', '>=', 'Patrol').where('name', '<', 'Patrom').get(),
  db.collection('patients').where('destination', '>=', 'Patrol').where('destination', '<', 'Patrom').get(),
]);
const patientDocs = new Map([...byName.docs, ...byDestination.docs].map((doc) => [doc.id, doc]));
for (const doc of patientDocs.values()) {
  console.log(`${doc.id}  destination=${doc.data().destination}  status=${doc.data().status}`);
}
console.log(`Total: ${patientDocs.size}\n`);

if (credentialPath) {
  const fs = await import('node:fs');
  fs.unlinkSync(credentialPath);
}
