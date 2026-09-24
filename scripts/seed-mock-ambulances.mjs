#!/usr/bin/env node
// Manual dev-testing utility (not wired into CI) — seeds a batch of mock
// `ambulanceLocations` documents directly via the Admin SDK, bypassing
// firestore.rules and the publishAmbulanceLocation callable entirely
// (same "Admin SDK write" shortcut audit-e2e-leftovers.mjs's own header
// comment describes for reading test debris), so the physician app's
// Multiple Ambulance View has real fleet-scale data to look at without
// needing 30 real EMS devices/accounts signed in and driving around.
//
// Targets 'test-org' — the same org run-physician-patrol-test.mjs/
// run-ems-patrol-test.mjs already seed into, and (checked directly
// against amdash-dev) already has enableMultipleAmbulanceView: true set.
//
// Usage: node seed-mock-ambulances.mjs [count]
//   count: how many ambulances to seed (default 30)
//
// Idempotent — reuses the exact same docId scheme
// ambulanceLocationRef (functions/src/ems.ts) does
// (sha256(`${organizationId}:${ambulanceId}`)), so re-running this
// overwrites the same docs rather than piling up duplicates on every run.
import crypto from 'node:crypto';
import { Timestamp, getFirestore } from 'firebase-admin/firestore';
import { findOrganizationId, initFirebaseAdmin } from './lib/firebase-admin-cli.mjs';

const credentialPath = initFirebaseAdmin('seed-mock-ambulances');
const db = getFirestore();

const count = Number(process.argv[2]) || 30;

// Ottawa-area center — matches the lat/lng every existing hospital/patient
// fixture in this codebase already clusters around (e.g.
// patient_viewer_test.dart's own _hospital at 45.40/-75.75), so the
// seeded fleet reads as a real, visually grouped map instead of 30 pins
// scattered across the globe.
const CENTER_LAT = 45.4215;
const CENTER_LNG = -75.6972;
const SPREAD_DEGREES = 0.06; // roughly a 6-7km radius

function docIdFor(organizationId, ambulanceId) {
  return crypto.createHash('sha256').update(`${organizationId}:${ambulanceId}`).digest('hex');
}

function randomOffset() {
  return (Math.random() - 0.5) * 2 * SPREAD_DEGREES;
}

const organizationId = await findOrganizationId(db, 'test-org');

const batch = db.batch();
const nowMs = Date.now();
let transportingCount = 0;
let staleCount = 0;

for (let i = 1; i <= count; i++) {
  const ambulanceId = `Unit ${i}`;
  // Roughly 40% transporting, 60% empty — enough of each to exercise
  // both the "All Ambulances" and "Empty" filter tabs, and both marker/
  // pill visuals, in one seed.
  const isTransporting = Math.random() < 0.4;
  // Every 10th ambulance is deliberately stale — older than
  // ambulanceStaleAfterMs's 150s threshold (see
  // ambulance_location_service.dart) — so the "Lost Connection" pill and
  // the marker's own "Last updated at" info-window text both have
  // something real to show too, not just the two live states.
  const isStale = i % 10 === 0;
  const updatedAtMs = isStale ? nowMs - 5 * 60 * 1000 : nowMs;

  if (isTransporting) transportingCount++;
  if (isStale) staleCount++;

  const ref = db.collection('ambulanceLocations').doc(docIdFor(organizationId, ambulanceId));
  batch.set(ref, {
    ambulanceId,
    organizationId,
    latitude: CENTER_LAT + randomOffset(),
    longitude: CENTER_LNG + randomOffset(),
    isTransporting,
    updatedAt: Timestamp.fromMillis(updatedAtMs),
    publishedByUid: 'seed-mock-ambulances-script',
  });
}

await batch.commit();

console.log(`Seeded ${count} ambulances into test-org (${organizationId}):`);
console.log(`  ${transportingCount} transporting, ${count - transportingCount} empty, ${staleCount} stale.`);
console.log('Sign into physician-web and switch to "All Ambulances" or "Empty" to see them.');

if (credentialPath) {
  const fs = await import('node:fs');
  fs.unlinkSync(credentialPath);
}
