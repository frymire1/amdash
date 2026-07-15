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

interface CreateUserRequest {
  email: string;
  firstName: string;
  lastName: string;
  role: AssignableRole;
}

interface SetInitialPasswordRequest {
  email: string;
  password: string;
}

interface CheckAccountStatusRequest {
  email: string;
}

interface SetUserRoleRequest {
  email: string;
  role: AssignableRole;
}

interface RemoveUserRoleRequest {
  email: string;
  role: AssignableRole;
}

async function callerIsAdmin(uid: string): Promise<boolean> {
  const snapshot = await getFirestore().collection('users').doc(uid).get();
  const roles = snapshot.data()?.['role'];
  return Array.isArray(roles) && roles.includes('admin');
}

async function findUserByEmail(email: string) {
  try {
    return await getAuth().getUserByEmail(email);
  } catch {
    throw new HttpsError('not-found', `No account found for ${email}.`);
  }
}

// Creates a brand-new account with no password set — the admin never
// chooses or sees a credential. The new user sets their own password the
// first time they enter this email on the login page (it checks
// checkAccountStatus, sees hasPassword: false, and routes to the
// set-password screen, which calls setInitialPassword below), or via
// "Forgot password?".
export const createUser = onCall<CreateUserRequest>({ region: REGION }, async (request) => {
  if (!request.auth || !(await callerIsAdmin(request.auth.uid))) {
    throw new HttpsError('permission-denied', 'Only admins can create users.');
  }

  const { email, firstName, lastName, role } = request.data;
  if (!email || !firstName || !lastName || !ASSIGNABLE_ROLES.includes(role)) {
    throw new HttpsError(
      'invalid-argument',
      'A valid email, first name, last name, and role (ems, physician, or nurse) are required.',
    );
  }

  let newUser;
  try {
    newUser = await getAuth().createUser({ email });
  } catch (error) {
    if ((error as { code?: string }).code === 'auth/email-already-exists') {
      throw new HttpsError('already-exists', `An account with ${email} already exists.`);
    }
    throw new HttpsError('internal', 'Failed to create the account.');
  }

  await getFirestore().collection('users').doc(newUser.uid).set({ email, firstName, lastName, role: [role] });

  return { uid: newUser.uid, email, firstName, lastName, role };
});

// Deliberately callable without being signed in — the login page uses this
// to decide, from just an email, whether to show a "set your password"
// screen (no account yet, or an admin-created account with no password) or
// a normal single-password sign-in screen. Returning `hasPassword` (rather
// than making the client guess from a failed sign-in attempt) is what lets
// the email-only-first flow work at all.
export const checkAccountStatus = onCall<CheckAccountStatusRequest>({ region: REGION }, async (request) => {
  const { email } = request.data;
  if (!email) {
    throw new HttpsError('invalid-argument', 'A valid email is required.');
  }

  try {
    const user = await getAuth().getUserByEmail(email);
    const hasPassword = user.providerData.some((provider) => provider.providerId === 'password');
    return { exists: true, hasPassword };
  } catch {
    return { exists: false, hasPassword: false };
  }
});

// Deliberately callable without being signed in — the whole point is to let
// someone set their FIRST password before they've ever authenticated. This
// is safe only because of the check below: it flatly refuses to touch any
// account that already has a password credential, so it can never be used
// to take over an existing account just by knowing its email. An account
// that already has a password must go through "Forgot password?" instead,
// same as if this function didn't exist.
export const setInitialPassword = onCall<SetInitialPasswordRequest>({ region: REGION }, async (request) => {
  const { email, password } = request.data;
  if (!email || !password || password.length < 6) {
    throw new HttpsError('invalid-argument', 'A valid email and a password of at least 6 characters are required.');
  }

  const user = await findUserByEmail(email);

  const hasPassword = user.providerData.some((provider) => provider.providerId === 'password');
  if (hasPassword) {
    throw new HttpsError('already-exists', 'This account already has a password.');
  }

  await getAuth().updateUser(user.uid, { password });

  return { email: user.email };
});

// Adds a role to the user's existing roles (a user can hold more than one at
// once) rather than replacing them — see removeUserRole below for the
// inverse. Only ever called by an admin; clients can never write `role`
// themselves (see firestore.rules).
export const setUserRole = onCall<SetUserRoleRequest>({ region: REGION }, async (request) => {
  if (!request.auth || !(await callerIsAdmin(request.auth.uid))) {
    throw new HttpsError('permission-denied', 'Only admins can assign roles.');
  }

  const { email, role } = request.data;
  if (!email || !ASSIGNABLE_ROLES.includes(role)) {
    throw new HttpsError('invalid-argument', 'A valid email and role (ems, physician, or nurse) are required.');
  }

  const targetUser = await findUserByEmail(email);
  await getFirestore()
    .collection('users')
    .doc(targetUser.uid)
    .set({ role: FieldValue.arrayUnion(role) }, { merge: true });

  return { uid: targetUser.uid, email: targetUser.email, role };
});

export const removeUserRole = onCall<RemoveUserRoleRequest>({ region: REGION }, async (request) => {
  if (!request.auth || !(await callerIsAdmin(request.auth.uid))) {
    throw new HttpsError('permission-denied', 'Only admins can remove roles.');
  }

  const { email, role } = request.data;
  if (!email || !ASSIGNABLE_ROLES.includes(role)) {
    throw new HttpsError('invalid-argument', 'A valid email and role (ems, physician, or nurse) are required.');
  }

  const targetUser = await findUserByEmail(email);
  await getFirestore()
    .collection('users')
    .doc(targetUser.uid)
    .update({ role: FieldValue.arrayRemove(role) });

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
    const roles = profile?.['role'];
    return {
      uid: user.uid,
      email: user.email ?? '',
      firstName: profile?.['firstName'] ?? '',
      lastName: profile?.['lastName'] ?? '',
      role: Array.isArray(roles) ? roles : [],
    };
  });
});
