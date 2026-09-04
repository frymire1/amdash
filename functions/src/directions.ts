import { defineSecret } from 'firebase-functions/params';
import { getFirestore } from 'firebase-admin/firestore';
import { DirectionsApiResult } from './classes/directions-api-result';

// Shared by physician.ts's fetchDirections callable and ems.ts's
// proximity-alert threshold check (functions/src/ems.ts's
// onEmsLocationEvent) — both need a real driving ETA/route between two
// points, and there's no reason for two copies of the Directions REST call
// or its response parsing.
export const DIRECTIONS_API_KEY = defineSecret('DIRECTIONS_API_KEY');

export interface DirectionsRoute {
  durationText: string;
  durationSeconds: number;
  distanceText: string;
  polylinePoints: Array<[number, number]>;
}

// The actual Directions REST API call + response parsing.
export async function callDirectionsApi(
  originLat: number,
  originLng: number,
  destinationLat: number,
  destinationLng: number,
): Promise<DirectionsRoute | null> {
  const url =
    `https://maps.googleapis.com/maps/api/directions/json?origin=${originLat},${originLng}` +
    `&destination=${destinationLat},${destinationLng}&mode=driving&key=${DIRECTIONS_API_KEY.value()}`;
  const response = await fetch(url);
  const data = (await response.json()) as DirectionsApiResult;

  const route = data.routes?.[0];
  const leg = route?.legs?.[0];
  if (data.status !== 'OK' || !route || !leg) {
    // No route between two otherwise-valid points is a normal outcome
    // (e.g. ZERO_RESULTS), not an error worth throwing over.
    return null;
  }

  return {
    durationText: leg.duration.text,
    durationSeconds: leg.duration.value,
    distanceText: leg.distance.text,
    polylinePoints: decodePolyline(route.overview_polyline.points),
  };
}

// Decoded server-side, rather than sending the raw encoded string over a
// callable's JSON transport, after a real run showed the encoded string
// arriving corrupted on the web client (points decoded to wildly wrong
// coordinates — off by ~110° of longitude — even though this exact string
// decodes correctly here). Plain [lat, lng] number pairs are safe for any
// JSON transport; an encoded polyline string, which is sensitive to every
// individual byte being preserved exactly, evidently isn't guaranteed to
// survive it. Standard Google encoded-polyline algorithm decoder.
export function decodePolyline(encoded: string): Array<[number, number]> {
  const points: Array<[number, number]> = [];
  let index = 0;
  let lat = 0;
  let lng = 0;

  while (index < encoded.length) {
    let result = 0;
    let shift = 0;
    let b: number;
    do {
      b = encoded.charCodeAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lat += result & 1 ? ~(result >> 1) : result >> 1;

    result = 0;
    shift = 0;
    do {
      b = encoded.charCodeAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lng += result & 1 ? ~(result >> 1) : result >> 1;

    points.push([lat / 1e5, lng / 1e5]);
  }

  return points;
}

const EARTH_RADIUS_KM = 6371;

// Straight-line (great-circle) distance — pure math, no billed API call.
// Used as a cheap pre-filter ahead of a real callDirectionsApi call (see
// ems.ts's checkProximityAlertThresholds): calling the real Directions API
// on every ~15s-throttled-to-60s GPS tick for the whole duration of every
// tracked transport is real, non-trivial money at scale ($5/1,000
// requests, no meaningful free tier at volume) for ticks where the
// vehicle is nowhere near close enough to any threshold to plausibly have
// crossed one — this lets a caller skip the expensive call entirely for
// those ticks using only free Firestore reads + arithmetic already in
// hand.
export function haversineDistanceKm(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLng = ((lng2 - lng1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) ** 2 + Math.cos((lat1 * Math.PI) / 180) * Math.cos((lat2 * Math.PI) / 180) * Math.sin(dLng / 2) ** 2;
  return EARTH_RADIUS_KM * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// Shared hospital-lookup — resolve a patient's destination hospital name
// (plaintext, not PII — see patient-data.ts's own comments on why
// `destination` is safe to query directly) to real lat/lng, the input
// callDirectionsApi needs. Used by ems.ts's proximity check; previously
// inlined in physician.ts's now-deleted estimateArrivalDuration.
export async function resolveDestinationHospitalLatLng(
  organizationId: string,
  destinationName: string,
): Promise<{ latitude: number; longitude: number } | null> {
  const hospitalSnapshot = await getFirestore()
    .collection('hospitals')
    .where('organizationId', '==', organizationId)
    .where('name', '==', destinationName)
    .limit(1)
    .get();
  const hospital = hospitalSnapshot.docs[0]?.data();
  const latitude = hospital?.['latitude'];
  const longitude = hospital?.['longitude'];
  if (typeof latitude !== 'number' || typeof longitude !== 'number') {
    return null;
  }
  return { latitude, longitude };
}
