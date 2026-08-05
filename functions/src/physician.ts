import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { onDocumentCreated } from 'firebase-functions/v2/firestore';
import { defineSecret } from 'firebase-functions/params';
import { getMessaging } from 'firebase-admin/messaging';
import { FieldValue, Timestamp, getFirestore } from 'firebase-admin/firestore';
import { DirectionsApiResult } from './classes/directions-api-result';
import { FetchDirectionsRequest } from './classes/fetch-directions-request';
import { FetchDirectionsResponse } from './classes/fetch-directions-response';
import { REGION, getCallerProfile } from './shared';

const DIRECTIONS_API_KEY = defineSecret('DIRECTIONS_API_KEY');

// Fires whenever EMS uploads a new patient. Detection lives entirely here,
// server-side, rather than client-side Firestore watching — that's what
// makes delivery work even if a physician's tab (or browser) isn't open,
// which a client-side listener could never do.
export const sendNewPatientAlerts = onDocumentCreated({ document: 'patients/{patientId}', region: REGION }, async (event) => {
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
      body: typeof patient['name'] === 'string' && patient['name'] ? patient['name'] : 'A new patient has been uploaded.',
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
});

function isUnregisteredError(error: { code?: string } | undefined): boolean {
  return error?.code === 'messaging/registration-token-not-registered';
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
      return { found: false };
    }

    return {
      found: true,
      polylinePoints: decodePolyline(route.overview_polyline.points),
      durationText: leg.duration.text,
      distanceText: leg.distance.text,
    };
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
