import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { onMessagePublished } from 'firebase-functions/v2/pubsub';
import { initializeApp } from 'firebase-admin/app';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';
import { PubSub } from '@google-cloud/pubsub';

initializeApp();

const LOCATION_TOPIC = 'ems-location-updates';
const REGION = 'northamerica-northeast2';
const pubsub = new PubSub();

interface EmsLocationEvent {
  patientId: string;
  active: boolean;
  latitude?: number;
  longitude?: number;
}

interface PublishLocationRequest {
  patientId: string;
  latitude: number;
  longitude: number;
}

interface StopLocationRequest {
  patientId: string;
}

export const publishEmsLocation = onCall<PublishLocationRequest>({ region: REGION }, async (request) => {
  const { patientId, latitude, longitude } = request.data;

  if (!patientId || typeof latitude !== 'number' || typeof longitude !== 'number') {
    throw new HttpsError('invalid-argument', 'patientId, latitude, and longitude are required.');
  }

  const event: EmsLocationEvent = { patientId, active: true, latitude, longitude };
  await pubsub.topic(LOCATION_TOPIC).publishMessage({ json: event });

  return { published: true };
});

export const stopEmsLocation = onCall<StopLocationRequest>({ region: REGION }, async (request) => {
  const { patientId } = request.data;

  if (!patientId) {
    throw new HttpsError('invalid-argument', 'patientId is required.');
  }

  const event: EmsLocationEvent = { patientId, active: false };
  await pubsub.topic(LOCATION_TOPIC).publishMessage({ json: event });

  return { published: true };
});

export const onEmsLocationEvent = onMessagePublished(
  { topic: LOCATION_TOPIC, region: REGION },
  async (event) => {
    const data = event.data.message.json as EmsLocationEvent | undefined;

    if (!data?.patientId) {
      console.error('Received EMS location event without a patientId', data);
      return;
    }

    const update: Record<string, unknown> = {
      patientId: data.patientId,
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
