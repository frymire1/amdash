import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { defineSecret } from 'firebase-functions/params';
import { getAuth } from 'firebase-admin/auth';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';
import { AssignableRole } from './classes/assignable-role';
import { CallerProfile } from './classes/caller-profile';
import { CreateUserRequest } from './classes/create-user-request';
import { SetUserRoleRequest } from './classes/set-user-role-request';
import { RemoveUserRoleRequest } from './classes/remove-user-role-request';
import { CreateHospitalRequest } from './classes/create-hospital-request';
import { DeleteHospitalRequest } from './classes/delete-hospital-request';
import { CreateOrganizationRequest } from './classes/create-organization-request';
import { GeocodeResult } from './classes/geocode-result';
import { REGION, findUserByEmail, getCallerProfile } from './shared';

const GEOCODING_API_KEY = defineSecret('GEOCODING_API_KEY');

const ASSIGNABLE_ROLES: readonly AssignableRole[] = ['ems', 'physician', 'nurse'];

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

// setUserRole/removeUserRole/deleteHospital all take an opaque id (an email
// or a hospitalId) that could name a doc in ANY organization, not just the
// caller's own — this confirms the target actually belongs to the caller's
// org before the mutation proceeds, the same way patientOrganizationId does
// for EMS location updates (see ems.ts).
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
