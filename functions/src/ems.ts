import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { onMessagePublished } from 'firebase-functions/v2/pubsub';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';
import { PubSub } from '@google-cloud/pubsub';
import { CallerProfile } from './classes/caller-profile';
import { EmsLocationEvent } from './classes/ems-location-event';
import { PublishLocationRequest } from './classes/publish-location-request';
import { StopLocationRequest } from './classes/stop-location-request';
import { REGION, getCallerProfile } from './shared';

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
  // silently losing that location update.
  { topic: LOCATION_TOPIC, region: REGION, retry: true },
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

    if (typeof data.latitude === 'number' && typeof data.longitude === 'number') {
      update['latitude'] = data.latitude;
      update['longitude'] = data.longitude;
    }

    await getFirestore().collection('emsLocations').doc(data.patientId).set(update, { merge: true });
  },
);
