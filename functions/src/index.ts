import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { onMessagePublished } from 'firebase-functions/v2/pubsub';
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';
import { PubSub } from '@google-cloud/pubsub';

initializeApp();

const LOCATION_TOPIC = 'ems-location-updates';
const REGION = 'northamerica-northeast2';
const pubsub = new PubSub();

const ASSIGNABLE_ROLES = ['ems', 'physician', 'nurse'] as const;
type AssignableRole = (typeof ASSIGNABLE_ROLES)[number];

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

interface SetUserRoleRequest {
  email: string;
  role: AssignableRole;
}

async function callerIsAdmin(uid: string): Promise<boolean> {
  const snapshot = await getFirestore().collection('users').doc(uid).get();
  return snapshot.exists && snapshot.data()?.['role'] === 'admin';
}

export const setUserRole = onCall<SetUserRoleRequest>({ region: REGION }, async (request) => {
  if (!request.auth || !(await callerIsAdmin(request.auth.uid))) {
    throw new HttpsError('permission-denied', 'Only admins can assign roles.');
  }

  const { email, role } = request.data;
  if (!email || !ASSIGNABLE_ROLES.includes(role)) {
    throw new HttpsError('invalid-argument', 'A valid email and role (ems, physician, or nurse) are required.');
  }

  let targetUser;
  try {
    targetUser = await getAuth().getUserByEmail(email);
  } catch {
    throw new HttpsError('not-found', `No account found for ${email}.`);
  }

  await getFirestore().collection('users').doc(targetUser.uid).set({ role }, { merge: true });

  return { uid: targetUser.uid, email: targetUser.email, role };
});

export const listUsersWithRoles = onCall({ region: REGION }, async (request) => {
  if (!request.auth || !(await callerIsAdmin(request.auth.uid))) {
    throw new HttpsError('permission-denied', 'Only admins can list users.');
  }

  const [authUsers, profileDocs] = await Promise.all([
    getAuth().listUsers(1000),
    getFirestore().collection('users').get(),
  ]);

  const profilesByUid = new Map(profileDocs.docs.map((docSnapshot) => [docSnapshot.id, docSnapshot.data()]));

  return authUsers.users.map((user) => {
    const profile = profilesByUid.get(user.uid);
    return {
      uid: user.uid,
      email: user.email ?? '',
      firstName: profile?.['firstName'] ?? '',
      lastName: profile?.['lastName'] ?? '',
      role: profile?.['role'] ?? null,
    };
  });
});
