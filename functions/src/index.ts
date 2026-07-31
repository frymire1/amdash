import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { onMessagePublished } from 'firebase-functions/v2/pubsub';
import { defineSecret } from 'firebase-functions/params';
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';
import { PubSub } from '@google-cloud/pubsub';
import { AssignableRole } from './classes/assignable-role';
import { UserRole } from './classes/user-role';
import { CallerProfile } from './classes/caller-profile';
import { EmsLocationEvent } from './classes/ems-location-event';
import { PublishLocationRequest } from './classes/publish-location-request';
import { StopLocationRequest } from './classes/stop-location-request';
import { CreateUserRequest } from './classes/create-user-request';
import { SetInitialPasswordRequest } from './classes/set-initial-password-request';
import { CheckAccountStatusRequest } from './classes/check-account-status-request';
import { SetUserRoleRequest } from './classes/set-user-role-request';
import { RemoveUserRoleRequest } from './classes/remove-user-role-request';
import { CreateHospitalRequest } from './classes/create-hospital-request';
import { DeleteHospitalRequest } from './classes/delete-hospital-request';
import { CreateOrganizationRequest } from './classes/create-organization-request';
import { GeocodeResult } from './classes/geocode-result';

initializeApp();

const LOCATION_TOPIC = 'ems-location-updates';
const REGION = 'northamerica-northeast2';
const pubsub = new PubSub();
const GEOCODING_API_KEY = defineSecret('GEOCODING_API_KEY');

const ASSIGNABLE_ROLES: readonly AssignableRole[] = ['ems', 'physician', 'nurse'];

// The one place every Cloud Function reads a caller's role/org — a single
// `users/{uid}` read, reused by every requireAdmin/requireSuperAdmin/manual
// role check below, rather than each function re-implementing its own
// lookup (that's what callerIsAdmin used to be, before organizations existed
// and a second field — organizationId — needed reading alongside role).
async function getCallerProfile(uid: string | undefined): Promise<CallerProfile> {
  if (!uid) {
    throw new HttpsError('unauthenticated', 'You must be signed in.');
  }
  const snapshot = await getFirestore().collection('users').doc(uid).get();
  const data = snapshot.data();
  const role = data?.['role'];
  return {
    role: Array.isArray(role) ? (role as UserRole[]) : [],
    organizationId: data?.['organizationId'],
  };
}

// Every caller of this is an org-scoped operation (creates/lists/deletes a
// resource under the caller's own organizationId) — 'admin' alone isn't
// enough to guarantee that field exists.
function requireAdmin(profile: CallerProfile, message = 'Only admins can do this.'): void {
  if (!profile.role.includes('admin')) {
    throw new HttpsError('permission-denied', message);
  }
  if (!profile.organizationId) {
    throw new HttpsError(
      'failed-precondition',
      "Your account has the admin role but isn't part of an organization, so it can't do this."
    );
  }
}

function requireSuperAdmin(profile: CallerProfile, message = 'Only the head-admin can do this.'): void {
  if (!profile.role.includes('super-admin')) {
    throw new HttpsError('permission-denied', message);
  }
}

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

async function findUserByEmail(email: string) {
  try {
    return await getAuth().getUserByEmail(email);
  } catch {
    throw new HttpsError('not-found', `No account found for ${email}.`);
  }
}

// setUserRole/removeUserRole/deleteHospital all take an opaque id (an email
// or a hospitalId) that could name a doc in ANY organization, not just the
// caller's own — this confirms the target actually belongs to the caller's
// org before the mutation proceeds, the same way patientOrganizationId does
// for EMS location updates above.
function requireSameOrg(caller: CallerProfile, targetOrganizationId: unknown, message: string): void {
  if (targetOrganizationId !== caller.organizationId) {
    throw new HttpsError('permission-denied', message);
  }
}

// Creates a brand-new account with no password set — the admin never
// chooses or sees a credential. The new user sets their own password the
// first time they enter this email on the login page (it checks
// checkAccountStatus, sees hasPassword: false, and routes to the
// set-password screen, which calls setInitialPassword below), or via
// "Forgot password?".
export const createUser = onCall<CreateUserRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can create users.');

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

  // Always the caller's own org — never client-supplied, so an org-admin can
  // never seed a user into a different organization.
  await getFirestore()
    .collection('users')
    .doc(newUser.uid)
    .set({ email, firstName, lastName, role: [role], organizationId: profile.organizationId });

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
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can assign roles.');

  const { email, role } = request.data;
  if (!email || !ASSIGNABLE_ROLES.includes(role)) {
    throw new HttpsError('invalid-argument', 'A valid email and role (ems, physician, or nurse) are required.');
  }

  const targetUser = await findUserByEmail(email);
  const targetDocRef = getFirestore().collection('users').doc(targetUser.uid);
  const targetDoc = await targetDocRef.get();
  requireSameOrg(profile, targetDoc.data()?.['organizationId'], `${email} is not a member of your organization.`);

  await targetDocRef.set({ role: FieldValue.arrayUnion(role) }, { merge: true });

  return { uid: targetUser.uid, email: targetUser.email, role };
});

export const removeUserRole = onCall<RemoveUserRoleRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can remove roles.');

  const { email, role } = request.data;
  if (!email || !ASSIGNABLE_ROLES.includes(role)) {
    throw new HttpsError('invalid-argument', 'A valid email and role (ems, physician, or nurse) are required.');
  }

  const targetUser = await findUserByEmail(email);
  const targetDocRef = getFirestore().collection('users').doc(targetUser.uid);
  const targetDoc = await targetDocRef.get();
  requireSameOrg(profile, targetDoc.data()?.['organizationId'], `${email} is not a member of your organization.`);

  await targetDocRef.update({ role: FieldValue.arrayRemove(role) });

  return { uid: targetUser.uid, email: targetUser.email, role };
});

// Firebase Auth has no organization concept, so listUsers(1000) (the old
// implementation) can only ever return the whole project regardless of org —
// this queries Firestore's own users collection instead, which both scopes
// the result to the caller's org and drops the old hard 1000-user,
// no-pagination cap that came from misusing the Auth Admin API for this.
export const listUsersWithRoles = onCall({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can list users.');

  const profileDocs = await getFirestore()
    .collection('users')
    .where('organizationId', '==', profile.organizationId)
    .get();

  return profileDocs.docs.map((docSnapshot) => {
    const data = docSnapshot.data();
    const roles = data['role'];
    return {
      uid: docSnapshot.id,
      email: data['email'] ?? '',
      firstName: data['firstName'] ?? '',
      lastName: data['lastName'] ?? '',
      role: Array.isArray(roles) ? roles : [],
    };
  });
});

// Looks up lat/long for a street address via the Google Maps Geocoding API,
// so an admin only has to type an address rather than coordinates — the
// physician app's distance-sort feature needs real coordinates, not just a
// display string. Requires the GEOCODING_API_KEY secret to be provisioned
// (`firebase functions:secrets:set GEOCODING_API_KEY`) with a key that has
// the Geocoding API enabled.
async function geocodeAddress(address: string): Promise<{ latitude: number; longitude: number }> {
  const url = `https://maps.googleapis.com/maps/api/geocode/json?address=${encodeURIComponent(address)}&key=${GEOCODING_API_KEY.value()}`;
  const response = await fetch(url);
  const data = (await response.json()) as GeocodeResult;

  const location = data.results?.[0]?.geometry?.location;
  if (data.status !== 'OK' || !location) {
    throw new HttpsError('not-found', `Could not find coordinates for "${address}". Check the address and try again.`);
  }

  return { latitude: location.lat, longitude: location.lng };
}

// Hospitals are only ever written here (see firestore.rules) — clients,
// including the admin app, can't write to the hospitals collection
// directly, since geocoding the address has to happen server-side.
export const createHospital = onCall<CreateHospitalRequest>(
  { region: REGION, secrets: [GEOCODING_API_KEY] },
  async (request) => {
    const profile = await getCallerProfile(request.auth?.uid);
    requireAdmin(profile, 'Only admins can create hospitals.');

    const { name, address } = request.data;
    if (!name || !address) {
      throw new HttpsError('invalid-argument', 'A hospital name and address are required.');
    }

    const { latitude, longitude } = await geocodeAddress(address);

    const docRef = await getFirestore()
      .collection('hospitals')
      .add({ name, address, latitude, longitude, organizationId: profile.organizationId });

    return { id: docRef.id, name, address, latitude, longitude };
  },
);

export const deleteHospital = onCall<DeleteHospitalRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can delete hospitals.');

  const { hospitalId } = request.data;
  if (!hospitalId) {
    throw new HttpsError('invalid-argument', 'A hospitalId is required.');
  }

  const hospitalRef = getFirestore().collection('hospitals').doc(hospitalId);
  const hospitalDoc = await hospitalRef.get();
  requireSameOrg(profile, hospitalDoc.data()?.['organizationId'], 'That hospital belongs to a different organization.');

  await hospitalRef.delete();

  return { hospitalId };
});

// The only Cloud Function that can mint an 'admin' — createUser/
// setUserRole are structurally limited to ASSIGNABLE_ROLES (ems/physician/
// nurse), so this is the sole path to a new organization's first admin.
// Creates the Auth user before anything else: it's the one step that can
// fail on a duplicate email, so failing there first leaves nothing to clean
// up and is safe to retry immediately with the same input.
export const createOrganization = onCall<CreateOrganizationRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireSuperAdmin(profile, 'Only the super-admin can create organizations.');

  const { organizationName, adminEmail, adminFirstName, adminLastName } = request.data;
  if (!organizationName || !adminEmail || !adminFirstName || !adminLastName) {
    throw new HttpsError(
      'invalid-argument',
      'An organization name and the first admin\'s email, first name, and last name are required.',
    );
  }

  const existing = await getFirestore().collection('organizations').where('name', '==', organizationName).get();
  if (!existing.empty) {
    throw new HttpsError('already-exists', `An organization named "${organizationName}" already exists.`);
  }

  let newAdmin;
  try {
    newAdmin = await getAuth().createUser({ email: adminEmail });
  } catch (error) {
    if ((error as { code?: string }).code === 'auth/email-already-exists') {
      throw new HttpsError('already-exists', `An account with ${adminEmail} already exists.`);
    }
    throw new HttpsError('internal', 'Failed to create the admin account.');
  }

  const orgRef = await getFirestore()
    .collection('organizations')
    .add({ name: organizationName, createdAt: FieldValue.serverTimestamp(), createdBy: request.auth?.uid });

  await getFirestore().collection('users').doc(newAdmin.uid).set({
    email: adminEmail,
    firstName: adminFirstName,
    lastName: adminLastName,
    role: ['admin'],
    organizationId: orgRef.id,
  });

  return {
    organizationId: orgRef.id,
    organizationName,
    adminUid: newAdmin.uid,
    adminEmail,
  };
});
