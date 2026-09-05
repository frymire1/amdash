import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { getMessaging } from 'firebase-admin/messaging';
import { FieldValue, Timestamp, getFirestore } from 'firebase-admin/firestore';
import { DIRECTIONS_API_KEY, callDirectionsApi } from './directions';
import { FetchDirectionsRequest } from './classes/fetch-directions-request';
import { FetchDirectionsResponse } from './classes/fetch-directions-response';
import { REGION, getCallerProfile } from './auth';

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

    // Explicit fields, not a `...route` spread — directions.ts's
    // DirectionsRoute also carries durationSeconds (needed by ems.ts's
    // proximity-alert threshold math), which has no reason to leak into
    // this client-facing response shape.
    return { found: true, durationText: route.durationText, distanceText: route.distanceText, polylinePoints: route.polylinePoints };
  },
);

// Mirrors isProvidedValue (flutter/packages/amdash_core/lib/src/models/
// patient.dart) — a field counts as "provided" if it's a number, or a
// non-empty string that isn't the literal blank-field sentinel 'Unknown'
// EMS writes for a field left blank.
export function isProvided(value: unknown): boolean {
  if (typeof value === 'number') return true;
  if (typeof value === 'string') return value.length > 0 && value !== 'Unknown';
  return false;
}

export function demographicText(age: unknown, gender: unknown): string {
  const ageKnown = isProvided(age);
  const genderKnown = isProvided(gender);
  if (ageKnown && genderKnown) return `${age}, ${gender}`;
  if (ageKnown) return `${age}`;
  if (genderKnown) return `${gender}`;
  return 'A patient';
}

export function isUnregisteredError(error: { code?: string } | undefined): boolean {
  return error?.code === 'messaging/registration-token-not-registered';
}

// Structural subset of FirebaseFirestore.QueryDocumentSnapshot that
// sendAlertPush actually needs — just enough to read fcmTokens and write
// back to the same doc. A real query's own `.docs` (QueryDocumentSnapshot[])
// already satisfies this with no cast; ems.ts's notifyEmsConnectivityLoss
// (a single doc from `.doc(uid).get()`, not a query result — its own
// DocumentSnapshot has an optional `data()`, so it isn't a
// QueryDocumentSnapshot) satisfies it too, by wrapping in a one-line
// object literal instead of needing a whole fake QuerySnapshot.
interface AlertRecipientDoc {
  ref: FirebaseFirestore.DocumentReference;
  data(): FirebaseFirestore.DocumentData;
}

// Shared by every push alert this app sends, physician- or EMS-facing —
// sends one multicast to every token across every given user doc, then
// prunes whichever individual tokens FCM reports as permanently dead
// (unregistered/invalid) from their owning doc, so they don't keep
// silently failing on every future alert. Extracted from the old
// sendNewPatientAlerts (now deleted — see notifyPatientProximity below,
// its replacement) so this logic has exactly one copy.
export async function sendAlertPush(
  userDocs: AlertRecipientDoc[],
  title: string,
  body: string,
): Promise<void> {
  const tokensByUser = userDocs.map((userDoc) => ({
    ref: userDoc.ref,
    tokens: (userDoc.data()['fcmTokens'] as string[] | undefined) ?? [],
  }));
  const allTokens = tokensByUser.flatMap((user) => user.tokens);
  if (allTokens.length === 0) {
    return;
  }

  // notification (not just data) is required for this to actually display
  // anything on a backgrounded/killed app without any app-side handler —
  // confirmed for real (a manual iOS test received the permission prompt,
  // registered a token successfully, but no notification ever appeared).
  // Neither app registers a FirebaseMessaging.onMessage/onBackgroundMessage
  // Dart handler (nor an equivalent native one) to manually build a
  // notification from a data-only message the way this used to be sent —
  // that's the standard, required way to receive a *data-only* push
  // silently and show something yourself, and nothing here ever did it.
  // A `notification` field is what lets the OS (Android's system tray,
  // iOS's APNs alert) display it automatically instead, the same way any
  // other app's push notifications work, with zero custom handling code
  // needed. `data` is kept alongside it, unchanged — the web service
  // worker (web/firebase-messaging-sw.js) still reads `payload.data`
  // directly off the raw Push API event exactly as before; adding
  // `notification` doesn't change what reaches it.
  const response = await getMessaging().sendEachForMulticast({
    tokens: allTokens,
    notification: { title, body },
    data: { title, body },
  });

  if (response.failureCount > 0) {
    response.responses.forEach((result, index) => {
      if (!result.success) {
        console.error(`sendAlertPush: token ${index} failed`, result.error?.code, result.error?.message);
      }
    });
  }

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
}

// Called by ems.ts's onEmsLocationEvent once it detects a tracked
// patient's ETA has newly crossed one or more of a physician's chosen
// proximity thresholds (functions/src/ems.ts — see that file for the
// detection/throttle logic; this only owns "who gets told, and what it
// says"). Replaces the old sendNewPatientAlerts entirely — physicians no
// longer get pinged the instant a patient is uploaded regardless of
// distance (confirmed unwanted: an immediate ping for a patient 2 hours
// out is premature and was making the old alert feel redundant), only as
// they actually get close.
//
// Deliberately never includes anything that identifies a specific patient
// — name or healthcare number, encrypted or not. Firebase Cloud Messaging
// isn't a HIPAA-covered product (unlike Firestore/Cloud Functions/Cloud
// KMS — see the compliance checklist), so nothing patient-identifying
// should transit it at all, not even decrypted server-side first. Age +
// gender + how close they are is specific enough to be useful without
// naming anyone.
export async function notifyPatientProximity(
  patient: FirebaseFirestore.DocumentData,
  crossedThresholdsMinutes: number[],
): Promise<void> {
  const matching = await getFirestore()
    .collection('users')
    .where('organizationId', '==', patient['organizationId'])
    .where('workLocation', '==', patient['destination'])
    .where('newPatientAlertsExpiresAt', '>', Timestamp.now())
    .where('etaAlertThresholdsMinutes', 'array-contains-any', crossedThresholdsMinutes)
    .get();
  if (matching.empty) {
    return;
  }

  // The smallest (most urgent) newly-crossed threshold, even if a big ETA
  // jump between two throttled rechecks crossed more than one at once
  // (e.g. traffic clearing suddenly) — one push per recheck, not one per
  // threshold, so a physician never gets stacked simultaneous
  // notifications for a single event.
  const mostUrgentMinutes = Math.min(...crossedThresholdsMinutes);
  const body = `${demographicText(patient['age'], patient['gender'])} is about ${mostUrgentMinutes} minutes away.`;

  await sendAlertPush(matching.docs, 'Patient approaching', body);
}
