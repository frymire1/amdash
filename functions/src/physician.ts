import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { onDocumentCreated } from 'firebase-functions/v2/firestore';
import { logger } from 'firebase-functions/v2';
import { defineSecret } from 'firebase-functions/params';
import { getMessaging } from 'firebase-admin/messaging';
import { FieldValue, Timestamp, getFirestore } from 'firebase-admin/firestore';
import { DirectionsApiResult } from './classes/directions-api-result';
import { FetchDirectionsRequest } from './classes/fetch-directions-request';
import { FetchDirectionsResponse } from './classes/fetch-directions-response';
import { REGION, getCallerProfile, patientLocationRef } from './shared';

const DIRECTIONS_API_KEY = defineSecret('DIRECTIONS_API_KEY');

// Fires whenever EMS uploads a new patient. Detection lives entirely here,
// server-side, rather than client-side Firestore watching — that's what
// makes delivery work even if a physician's tab (or browser) isn't open,
// which a client-side listener could never do.
export const sendNewPatientAlerts = onDocumentCreated(
  { document: 'patients/{patientId}', region: REGION, secrets: [DIRECTIONS_API_KEY] },
  async (event) => {
    const patient = event.data?.data();
    if (!patient?.['organizationId'] || !patient?.['destination']) {
      return;
    }

    const matching = await getFirestore()
      .collection('users')
      .where('organizationId', '==', patient['organizationId'])
      .where('workLocation', '==', patient['destination'])
      .where('newPatientAlertsExpiresAt', '>', Timestamp.now())
      .get();

    const tokensByUser = matching.docs.map((userDoc) => ({
      ref: userDoc.ref,
      tokens: (userDoc.data()['fcmTokens'] as string[] | undefined) ?? [],
    }));
    const allTokens = tokensByUser.flatMap((user) => user.tokens);
    if (allTokens.length === 0) {
      return;
    }

    const response = await getMessaging().sendEachForMulticast({
      tokens: allTokens,
      data: {
        title: 'New patient inbound',
        body: await notificationBody(event.params.patientId, patient),
      },
    });

    if (response.failureCount > 0) {
      response.responses.forEach((result, index) => {
        if (!result.success) {
          console.error(`sendNewPatientAlerts: token ${index} failed`, result.error?.code, result.error?.message);
        }
      });
    }

    // A token FCM reports as unregistered/invalid is permanently dead — prune
    // it from whichever user doc(s) held it so it doesn't keep silently
    // failing on every future patient.
    const deadTokens = new Set(
      response.responses
        .map((result, index) => (!result.success && isUnregisteredError(result.error) ? allTokens[index] : undefined))
        .filter((token): token is string => !!token),
    );
    if (deadTokens.size === 0) {
      return;
    }

    await Promise.all(
      tokensByUser
        .filter((user) => user.tokens.some((token) => deadTokens.has(token)))
        .map((user) => user.ref.update({ fcmTokens: FieldValue.arrayRemove(...user.tokens.filter((token) => deadTokens.has(token))) })),
    );
  },
);

function isUnregisteredError(error: { code?: string } | undefined): boolean {
  return error?.code === 'messaging/registration-token-not-registered';
}

// Deliberately never includes anything that identifies a specific patient —
// name or healthcare number, encrypted or not. Firebase Cloud Messaging
// isn't a HIPAA-covered product (unlike Firestore/Cloud Functions/Cloud
// KMS — see the compliance checklist), so nothing patient-identifying
// should transit it at all, not even decrypted server-side first. Age +
// gender + an ETA is specific enough to be useful without naming anyone.
async function notificationBody(patientId: string, patient: FirebaseFirestore.DocumentData): Promise<string> {
  const demographic = demographicText(patient['age'], patient['gender']);
  const duration = await estimateArrivalDuration(patientId, patient);
  return duration ? `${demographic} is arriving in ${duration}.` : `${demographic} is inbound.`;
}

// Mirrors isProvidedValue (flutter/packages/amdash_core/lib/src/models/
// patient.dart) — a field counts as "provided" if it's a number, or a
// non-empty string that isn't the literal blank-field sentinel 'Unknown'
// EMS writes for a field left blank.
function isProvided(value: unknown): boolean {
  if (typeof value === 'number') return true;
  if (typeof value === 'string') return value.length > 0 && value !== 'Unknown';
  return false;
}

function demographicText(age: unknown, gender: unknown): string {
  const ageKnown = isProvided(age);
  const genderKnown = isProvided(gender);
  if (ageKnown && genderKnown) return `${age}, ${gender}`;
  if (ageKnown) return `${age}`;
  if (genderKnown) return `${gender}`;
  return 'A patient';
}

// Best-effort, one-shot estimate from the patient's live tracked position
// (not a live-*updating* value the way PatientViewer's own map card is —
// that one re-fetches as the vehicle keeps moving; this fires once, right
// as the patient doc is created). Reads patients/{patientId}/location/
// current rather than anything on the patient doc itself — reliably
// already there by this point (not a race) because uploadPatientDocument
// writes both in the same atomic batch, so this document and the trigger
// that calls this function become visible together. Null whenever any
// input for a real estimate is missing — live tracking was off, a
// destination that doesn't match any hospital on record, or a route the
// Directions API couldn't find — so the caller falls back to a
// demographic-only notification rather than a wrong or placeholder ETA.
async function estimateArrivalDuration(patientId: string, patient: FirebaseFirestore.DocumentData): Promise<string | null> {
  const location = (await patientLocationRef(patientId).get()).data();
  const originLat = location?.['latitude'];
  const originLng = location?.['longitude'];
  if (typeof originLat !== 'number' || typeof originLng !== 'number') {
    return null;
  }

  const organizationId = patient['organizationId'];
  const destination = patient['destination'];
  const hospitalSnapshot = await getFirestore()
    .collection('hospitals')
    .where('organizationId', '==', organizationId)
    .where('name', '==', destination)
    .limit(1)
    .get();
  const hospital = hospitalSnapshot.docs[0]?.data();
  const destinationLat = hospital?.['latitude'];
  const destinationLng = hospital?.['longitude'];
  if (typeof destinationLat !== 'number' || typeof destinationLng !== 'number') {
    return null;
  }

  try {
    const route = await callDirectionsApi(originLat, originLng, destinationLat, destinationLng);
    return route?.durationText ?? null;
  } catch (error) {
    logger.error('Failed to estimate arrival duration for a new-patient alert', error);
    return null;
  }
}

interface DirectionsRoute {
  durationText: string;
  distanceText: string;
  polylinePoints: Array<[number, number]>;
}

// The actual Directions REST API call + response parsing, shared by
// estimateArrivalDuration above (which only needs durationText) and the
// fetchDirections callable below (which returns the full route) — one
// implementation of the request/parsing logic rather than two.
async function callDirectionsApi(
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
    distanceText: leg.distance.text,
    polylinePoints: decodePolyline(route.overview_polyline.points),
  };
}

// Proxies the Directions REST API server-side. The classic Directions API
// never sends CORS headers — it was only ever designed for server-side or
// native-app callers — so PatientViewer's web build can't call it directly
// (confirmed via a real browser CORS block: "No 'Access-Control-Allow-Origin'
// header is present"). Native iOS/Android builds never hit this (CORS is a
// browser-only restriction), but routing everything through here keeps one
// code path for all platforms and keeps the API key server-side entirely,
// rather than embedded in client-visible JS. Requires the
// DIRECTIONS_API_KEY secret to be provisioned
// (`firebase functions:secrets:set DIRECTIONS_API_KEY`) with a key that has
// the Directions API enabled.
export const fetchDirections = onCall<FetchDirectionsRequest>(
  { region: REGION, secrets: [DIRECTIONS_API_KEY] },
  async (request): Promise<FetchDirectionsResponse> => {
    await getCallerProfile(request.auth?.uid); // must be signed in; throws otherwise

    const { originLat, originLng, destinationLat, destinationLng } = request.data;
    if (
      typeof originLat !== 'number' ||
      typeof originLng !== 'number' ||
      typeof destinationLat !== 'number' ||
      typeof destinationLng !== 'number'
    ) {
      throw new HttpsError(
        'invalid-argument',
        'originLat, originLng, destinationLat, and destinationLng are required.',
      );
    }

    const route = await callDirectionsApi(originLat, originLng, destinationLat, destinationLng);
    if (!route) {
      return { found: false };
    }

    return { found: true, ...route };
  },
);

// Decoded server-side, rather than sending the raw encoded string over the
// callable's JSON transport, after a real run showed the encoded string
// arriving corrupted on the web client (points decoded to wildly wrong
// coordinates — off by ~110° of longitude — even though this exact string
// decodes correctly here). Plain [lat, lng] number pairs are safe for any
// JSON transport; an encoded polyline string, which is sensitive to every
// individual byte being preserved exactly, evidently isn't guaranteed to
// survive it. Standard Google encoded-polyline algorithm decoder.
function decodePolyline(encoded: string): Array<[number, number]> {
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
