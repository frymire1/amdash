#!/usr/bin/env node
// Manual dev-testing/demo utility (not wired into CI) — companion to
// seed-mock-ambulances.mjs, but LIVE: keeps running and moves each
// ambulance along a straight-line route toward a random destination,
// updating Firestore every UPDATE_INTERVAL_MS so physician-web's own
// live AmbulanceLocationController listener picks up real, continuous
// movement — markers actually animate across the map instead of sitting
// on 30 static pins. Same docId scheme as seed-mock-ambulances.mjs
// (sha256(`${organizationId}:${ambulanceId}`)) and the same "Unit N"
// naming, so this can take over an already-seeded fleet or start fresh
// on its own — either way, run standalone.
//
// Usage: node simulate-ambulance-movement.mjs [count]
//   count: how many ambulances to simulate (default 30)
//
// Ctrl+C to stop. Bypasses firestore.rules and the publishAmbulanceLocation
// callable entirely (direct Admin SDK writes) — same shortcut every other
// script in this directory uses; this is dev/demo tooling, not something
// that exercises the real EMS-device publish path (see this repo's own
// README on real-device testing for that).
import crypto from 'node:crypto';
import { Timestamp, getFirestore } from 'firebase-admin/firestore';
import { findOrganizationId, initFirebaseAdmin } from './lib/firebase-admin-cli.mjs';

const credentialPath = initFirebaseAdmin('simulate-ambulances');
const db = getFirestore();

const count = Number(process.argv[2]) || 30;

// Same Ottawa-area footprint as seed-mock-ambulances.mjs.
const CENTER_LAT = 45.4215;
const CENTER_LNG = -75.6972;
const SPREAD_DEGREES = 0.06;

const UPDATE_INTERVAL_MS = 3000;
// Steps to cross one point-to-point route — fewer steps means a faster,
// more "urgent" looking drive. Transporting ambulances get there in
// roughly 8*3s = 24s; empty ones amble over roughly 20*3s = 60s, the same
// "urgent vs. patrolling" distinction a real fleet would show.
const TRANSPORTING_STEPS = 8;
const EMPTY_STEPS = 20;
// Chance a freshly-arrived ambulance picks up a patient (starts
// transporting) for its next route — mirrors seed-mock-ambulances.mjs's
// own ~40% split.
const TRANSPORTING_CHANCE = 0.4;

function docIdFor(organizationId, ambulanceId) {
  return crypto.createHash('sha256').update(`${organizationId}:${ambulanceId}`).digest('hex');
}

function randomPoint() {
  return {
    lat: CENTER_LAT + (Math.random() - 0.5) * 2 * SPREAD_DEGREES,
    lng: CENTER_LNG + (Math.random() - 0.5) * 2 * SPREAD_DEGREES,
  };
}

function newRoute(from) {
  const isTransporting = Math.random() < TRANSPORTING_CHANCE;
  return {
    from,
    to: randomPoint(),
    step: 0,
    totalSteps: isTransporting ? TRANSPORTING_STEPS : EMPTY_STEPS,
    isTransporting,
  };
}

function lerp(a, b, t) {
  return a + (b - a) * t;
}

const organizationId = await findOrganizationId(db, 'test-org');

const ambulances = [];
for (let i = 1; i <= count; i++) {
  const ambulanceId = `Unit ${i}`;
  const start = randomPoint();
  ambulances.push({ ambulanceId, route: newRoute(start) });
}

console.log(`Simulating ${count} ambulances driving around test-org (${organizationId}).`);
console.log(`Updating every ${UPDATE_INTERVAL_MS / 1000}s — open physician-web and watch "All Ambulances". Ctrl+C to stop.`);

let stopping = false;
process.on('SIGINT', () => {
  console.log('\nStopping after this tick...');
  stopping = true;
});

async function tick() {
  const batch = db.batch();
  const nowMs = Date.now();

  for (const ambulance of ambulances) {
    const route = ambulance.route;
    route.step++;
    const t = Math.min(route.step / route.totalSteps, 1);
    const position = { lat: lerp(route.from.lat, route.to.lat, t), lng: lerp(route.from.lng, route.to.lng, t) };

    if (t >= 1) {
      // Arrived — pick a new destination from here, possibly switching
      // transporting/empty for the next leg.
      ambulance.route = newRoute(position);
    }

    const ref = db.collection('ambulanceLocations').doc(docIdFor(organizationId, ambulance.ambulanceId));
    batch.set(ref, {
      ambulanceId: ambulance.ambulanceId,
      organizationId,
      latitude: position.lat,
      longitude: position.lng,
      isTransporting: route.isTransporting,
      updatedAt: Timestamp.fromMillis(nowMs),
      publishedByUid: 'simulate-ambulance-movement-script',
    });
  }

  await batch.commit();
}

while (!stopping) {
  await tick();
  await new Promise((resolve) => setTimeout(resolve, UPDATE_INTERVAL_MS));
}

if (credentialPath) {
  const fs = await import('node:fs');
  fs.unlinkSync(credentialPath);
}
console.log('Stopped.');
