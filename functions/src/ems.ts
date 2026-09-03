import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { onDocumentDeleted } from 'firebase-functions/v2/firestore';
import { onMessagePublished } from 'firebase-functions/v2/pubsub';
import { logger } from 'firebase-functions/v2';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';
import { PubSub } from '@google-cloud/pubsub';
import { CallerProfile } from './classes/caller-profile';
import { EmsLocationEvent } from './classes/ems-location-event';
import { PublishLocationRequest } from './classes/publish-location-request';
import { StopLocationRequest } from './classes/stop-location-request';
import { REGION, getCallerProfile } from './auth';
import { DIRECTIONS_API_KEY, callDirectionsApi, resolveDestinationHospitalLatLng } from './directions';
import { notifyPatientProximity } from './physician';
import { patientLocationRef } from './patient-data';

const LOCATION_TOPIC = 'ems-location-updates';
const pubsub = new PubSub();

export const publishEmsLocation = onCall<PublishLocationRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  if (!profile.role.includes('ems')) {
    throw new HttpsError('permission-denied', 'Only EMS accounts can publish a location update.');
  }

  const { patientId, latitude, longitude } = request.data;
  if (!patientId || typeof latitude !== 'number' || typeof longitude !== 'number') {
    throw new HttpsError('invalid-argument', 'patientId, latitude, and longitude are required.');
  }

  const organizationId = await patientOrganizationId(patientId, profile);

  const event: EmsLocationEvent = { patientId, organizationId, active: true, latitude, longitude };
  await pubsub.topic(LOCATION_TOPIC).publishMessage({ json: event });

  return { published: true };
});

export const stopEmsLocation = onCall<StopLocationRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  if (!profile.role.includes('ems')) {
    throw new HttpsError('permission-denied', 'Only EMS accounts can stop a location update.');
  }

  const { patientId } = request.data;
  if (!patientId) {
    throw new HttpsError('invalid-argument', 'patientId is required.');
  }

  const organizationId = await patientOrganizationId(patientId, profile);

  const event: EmsLocationEvent = { patientId, organizationId, active: false };
  await pubsub.topic(LOCATION_TOPIC).publishMessage({ json: event });

  return { published: true };
});

// Shared by publishEmsLocation/stopEmsLocation — reads the patient's own
// organizationId (never trusting a client-supplied one) and confirms the
// caller belongs to that same org before letting them publish anything
// about this patient.
async function patientOrganizationId(patientId: string, caller: CallerProfile): Promise<string> {
  const snapshot = await getFirestore().collection('patients').doc(patientId).get();
  const organizationId = snapshot.data()?.['organizationId'];
  if (!snapshot.exists || typeof organizationId !== 'string') {
    throw new HttpsError('not-found', `No patient found with id ${patientId}.`);
  }
  if (organizationId !== caller.organizationId) {
    throw new HttpsError('permission-denied', 'That patient belongs to a different organization.');
  }
  return organizationId;
}

export const onEmsLocationEvent = onMessagePublished(
  // retry: true — without it, Pub/Sub does not retry a failed delivery (a
  // cold-start timeout, a transient blip) at all; it just drops the message,
  // silently losing that location update. secrets — checkProximityAlertThresholds
  // below calls the Directions API via directions.ts.
  { topic: LOCATION_TOPIC, region: REGION, retry: true, secrets: [DIRECTIONS_API_KEY] },
  async (event) => {
    const data = event.data.message.json as EmsLocationEvent | undefined;

    if (!data?.patientId) {
      console.error('Received EMS location event without a patientId', data);
      return;
    }

    const update: Record<string, unknown> = {
      patientId: data.patientId,
      organizationId: data.organizationId,
      active: data.active,
      updatedAt: FieldValue.serverTimestamp(),
    };

    const hasFix = typeof data.latitude === 'number' && typeof data.longitude === 'number';
    if (hasFix) {
      update['latitude'] = data.latitude;
      update['longitude'] = data.longitude;
    }

    await patientLocationRef(data.patientId).set(update, { merge: true });

    // Proximity-alert threshold check — only meaningful for an active,
    // freshly-positioned patient. A patient EMS never enables live
    // tracking for simply never reaches this at all: confirmed
    // deliberately no fallback alert for that case (see physician.ts's
    // notifyPatientProximity doc comment — this replaced the old
    // always-fires-on-upload sendNewPatientAlerts entirely).
    if (data.active && hasFix) {
      await checkProximityAlertThresholds(data.patientId, data.latitude as number, data.longitude as number);
    }
  },
);

// At most one real ETA recheck per patient per minute — EMS's own GPS
// publish cadence is ~15s (ems_tracking_service.dart's _updateInterval),
// far more granular than a proximity alert needs (thresholds are 5+
// minutes apart), so onEmsLocationEvent above calls this on every tick but
// this throttles the actual work (a Firestore read of the hospital, a
// live Directions API call, and a possible push) down to ~once/minute —
// piggybacking on the already-frequent location pipeline rather than
// standing up a separate scheduled polling function.
const ETA_RECHECK_INTERVAL_MS = 60 * 1000;
const PROXIMITY_THRESHOLDS_MINUTES = [60, 30, 15, 5];

async function checkProximityAlertThresholds(patientId: string, latitude: number, longitude: number): Promise<void> {
  const locationRef = patientLocationRef(patientId);
  const locationSnapshot = await locationRef.get();
  const locationData = locationSnapshot.data();

  const lastEtaCheckAt = locationData?.['lastEtaCheckAt'] as FirebaseFirestore.Timestamp | undefined;
  if (lastEtaCheckAt && Date.now() - lastEtaCheckAt.toMillis() < ETA_RECHECK_INTERVAL_MS) {
    return;
  }

  const patientSnapshot = await getFirestore().collection('patients').doc(patientId).get();
  const patient = patientSnapshot.data();
  if (!patient?.['organizationId'] || !patient?.['destination']) {
    return;
  }

  const hospitalLatLng = await resolveDestinationHospitalLatLng(patient['organizationId'], patient['destination']);
  const route = hospitalLatLng
    ? await callDirectionsApi(latitude, longitude, hospitalLatLng.latitude, hospitalLatLng.longitude).catch((error) => {
        logger.error('Failed to check proximity-alert thresholds', error);
        return null;
      })
    : null;

  if (!route) {
    // No hospital match, no route found, or the Directions call itself
    // failed — nothing to compare against this time. Still stamp
    // lastEtaCheckAt so the throttle above doesn't retry on every single
    // ~15s tick until it eventually succeeds.
    await locationRef.set({ lastEtaCheckAt: FieldValue.serverTimestamp() }, { merge: true });
    return;
  }

  const etaMinutes = route.durationSeconds / 60;
  const alreadyNotified = new Set((locationData?.['notifiedThresholds'] as number[] | undefined) ?? []);
  const newlyCrossed = PROXIMITY_THRESHOLDS_MINUTES.filter(
    (threshold) => etaMinutes <= threshold && !alreadyNotified.has(threshold),
  );

  if (newlyCrossed.length > 0) {
    await notifyPatientProximity(patient, newlyCrossed);
  }

  await locationRef.set(
    {
      lastEtaCheckAt: FieldValue.serverTimestamp(),
      ...(newlyCrossed.length > 0 ? { notifiedThresholds: FieldValue.arrayUnion(...newlyCrossed) } : {}),
    },
    { merge: true },
  );
}

// A patient doc's subcollections — location/current, vitalsHistory/* —
// are only ever written by other Cloud Functions (firestore.rules blocks
// client writes there entirely), and deleting the parent patient doc does
// *not* cascade to them in Firestore, so nothing removes them unless
// something does it here. recursiveDelete sweeps every subcollection under
// this path, present or future, rather than listing each one by name and
// having to remember to add a new line here the next time a subcollection
// gets added. Triggering off the patients collection itself — rather than
// requiring every deletion path (the EMS app's delete button,
// cleanupCompletedPatients' retention sweep, manual console deletes) to
// remember this — means it can never drift out of sync with however a
// patient doc actually disappears.
export const onPatientDeleted = onDocumentDeleted({ document: 'patients/{patientId}', region: REGION }, async (event) => {
  await getFirestore().recursiveDelete(getFirestore().collection('patients').doc(event.params.patientId));
});
