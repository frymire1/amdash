import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { logger } from 'firebase-functions/v2';
import { defineSecret } from 'firebase-functions/params';
import { getAuth } from 'firebase-admin/auth';
import { FieldValue, Timestamp, getFirestore } from 'firebase-admin/firestore';
import { AssignableRole } from './classes/assignable-role';
import { AuditAction } from './classes/audit-action';
import { CallerProfile } from './classes/caller-profile';
import { CreateUserRequest } from './classes/create-user-request';
import { SetUserRoleRequest } from './classes/set-user-role-request';
import { RemoveUserRoleRequest } from './classes/remove-user-role-request';
import { UpdateUserRequest } from './classes/update-user-request';
import { DeleteUserRequest } from './classes/delete-user-request';
import { SetUserDisabledRequest } from './classes/set-user-disabled-request';
import { ResendInviteRequest } from './classes/resend-invite-request';
import { CreateHospitalRequest } from './classes/create-hospital-request';
import { UpdateHospitalRequest } from './classes/update-hospital-request';
import { DeleteHospitalRequest } from './classes/delete-hospital-request';
import { CreateOrganizationRequest } from './classes/create-organization-request';
import { SetOrganizationRetentionRequest } from './classes/set-organization-retention-request';
import { SetOrganizationCountryRequest } from './classes/set-organization-country-request';
import { SetOrganizationCmekRequest } from './classes/set-organization-cmek-request';
import { GeocodeResult } from './classes/geocode-result';
import { REGION, findUserByEmail, getCallerProfile } from './shared';
import { getOrCreateOrgKey } from './kms';
import { RESEND_API_KEY, sendWelcomeEmail } from './email';

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

// Best-effort — an audit log write failing shouldn't fail the mutation it
// was recording, same non-critical-notification rationale as
// sendWelcomeEmail in email.ts. No client ever reads/writes this
// collection directly (see firestore.rules); listAuditLog below is the
// only read path.
async function logAudit(entry: {
  action: AuditAction;
  actor: CallerProfile;
  organizationId: string | undefined;
  target?: string;
  details?: Record<string, unknown>;
}): Promise<void> {
  try {
    await getFirestore()
      .collection('auditLog')
      .add({
        action: entry.action,
        actorUid: entry.actor.uid,
        actorEmail: entry.actor.email,
        organizationId: entry.organizationId ?? null,
        target: entry.target ?? null,
        details: entry.details ?? null,
        timestamp: FieldValue.serverTimestamp(),
      });
  } catch (error) {
    logger.error('Failed to write audit log entry', { entry, error });
  }
}

// Blocks an action (delete or suspend) that would leave an organization
// with zero enabled admins. The only in-app path to grant `admin` is
// createOrganization (one per new org) — there's no "promote to admin"
// flow — so an org that loses its last admin here has no way to recover
// short of a super-admin editing Firestore directly. No-ops for a target
// that isn't an admin at all.
async function assertNotLastAdmin(organizationId: string, targetUid: string, action: string): Promise<void> {
  const targetDoc = await getFirestore().collection('users').doc(targetUid).get();
  const targetRoles = targetDoc.data()?.['role'];
  if (!Array.isArray(targetRoles) || !targetRoles.includes('admin')) {
    return;
  }

  const adminsSnapshot = await getFirestore()
    .collection('users')
    .where('organizationId', '==', organizationId)
    .where('role', 'array-contains', 'admin')
    .get();

  const remaining = adminsSnapshot.docs.filter((doc) => doc.id !== targetUid);
  if (remaining.length === 0) {
    throw new HttpsError('failed-precondition', `Can't ${action} the last admin in this organization.`);
  }
}

// Creates a brand-new account with no password set — the admin never
// chooses or sees a credential. The new user sets their own password the
// first time they enter this email on the login page (it checks
// checkAccountStatus, sees hasPassword: false, and routes to the
// set-password screen, which calls setInitialPassword below), or via
// "Forgot password?".
export const createUser = onCall<CreateUserRequest>({ region: REGION, secrets: [RESEND_API_KEY] }, async (request) => {
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

  // Best-effort — see email.ts: the account already exists and is usable
  // regardless of whether this send succeeds, so a failure here doesn't
  // fail the whole createUser call.
  await sendWelcomeEmail({ email, firstName, role });

  await logAudit({
    action: 'user.create',
    actor: profile,
    organizationId: profile.organizationId,
    target: newUser.uid,
    details: { email, role },
  });

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

  await logAudit({
    action: 'user.roleAdd',
    actor: profile,
    organizationId: profile.organizationId,
    target: targetUser.uid,
    details: { role },
  });

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

  await logAudit({
    action: 'user.roleRemove',
    actor: profile,
    organizationId: profile.organizationId,
    target: targetUser.uid,
    details: { role },
  });

  return { uid: targetUser.uid, email: targetUser.email, role };
});

// Backs the admin app's "Edit User" dialog — name and/or email, identified
// by uid (not email, since email itself may be what's changing). Updates
// Auth first (the step that can fail on a taken email) so a failure there
// leaves Firestore untouched, same ordering rationale as createUser.
export const updateUser = onCall<UpdateUserRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can edit users.');

  const { uid, email, firstName, lastName } = request.data;
  if (!uid || (!email && !firstName && !lastName)) {
    throw new HttpsError('invalid-argument', 'A uid and at least one of email, firstName, or lastName are required.');
  }

  const targetDocRef = getFirestore().collection('users').doc(uid);
  const targetDoc = await targetDocRef.get();
  if (!targetDoc.exists) {
    throw new HttpsError('not-found', 'That user no longer exists.');
  }
  requireSameOrg(profile, targetDoc.data()?.['organizationId'], 'That user is not a member of your organization.');

  if (email) {
    try {
      await getAuth().updateUser(uid, { email });
    } catch (error) {
      if ((error as { code?: string }).code === 'auth/email-already-exists') {
        throw new HttpsError('already-exists', `An account with ${email} already exists.`);
      }
      throw new HttpsError('internal', 'Failed to update the email address.');
    }
  }

  const firestoreUpdate: Record<string, string> = {};
  if (email) firestoreUpdate['email'] = email;
  if (firstName) firestoreUpdate['firstName'] = firstName;
  if (lastName) firestoreUpdate['lastName'] = lastName;
  await targetDocRef.update(firestoreUpdate);

  await logAudit({
    action: 'user.update',
    actor: profile,
    organizationId: profile.organizationId,
    target: uid,
    details: firestoreUpdate,
  });

  const data = targetDoc.data() ?? {};
  const role = data['role'];
  return {
    uid,
    email: firestoreUpdate['email'] ?? data['email'] ?? '',
    firstName: firestoreUpdate['firstName'] ?? data['firstName'] ?? '',
    lastName: firestoreUpdate['lastName'] ?? data['lastName'] ?? '',
    role: Array.isArray(role) ? role : [],
  };
});

// Deletes both the Auth account and the Firestore profile — Auth first,
// same ordering rationale as createUser/updateUser (the step most likely to
// fail leaves nothing behind to clean up). assertNotLastAdmin (rather than
// a blanket "can't delete yourself" check) is what actually prevents an org
// from losing its last admin — it also covers deleting a *different*
// last-admin account, and still lets a co-admin org offboard themselves
// once someone else can take over.
export const deleteUser = onCall<DeleteUserRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can delete users.');

  const { uid } = request.data;
  if (!uid) {
    throw new HttpsError('invalid-argument', 'A uid is required.');
  }

  const targetDocRef = getFirestore().collection('users').doc(uid);
  const targetDoc = await targetDocRef.get();
  if (!targetDoc.exists) {
    throw new HttpsError('not-found', 'That user no longer exists.');
  }
  const targetData = targetDoc.data() ?? {};
  requireSameOrg(profile, targetData['organizationId'], 'That user is not a member of your organization.');

  await assertNotLastAdmin(profile.organizationId as string, uid, 'delete');

  await getAuth().deleteUser(uid);
  await targetDocRef.delete();

  await logAudit({
    action: 'user.delete',
    actor: profile,
    organizationId: profile.organizationId,
    target: uid,
    details: { email: targetData['email'] },
  });

  return { uid };
});

// Suspends/reactivates an Auth account without deleting it — for e.g. "this
// person is on leave" or "investigating this account", where deleteUser
// would be destructive (and, via assertNotLastAdmin, is refused anyway for
// an org's last admin — the same guard applies to suspending one). A
// disabled account can't sign in (Firebase Auth enforces this directly)
// but keeps its history, role assignments, and Firestore profile intact.
export const setUserDisabled = onCall<SetUserDisabledRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can suspend or reactivate users.');

  const { uid, disabled } = request.data;
  if (!uid || typeof disabled !== 'boolean') {
    throw new HttpsError('invalid-argument', 'A uid and a disabled boolean are required.');
  }

  const targetDocRef = getFirestore().collection('users').doc(uid);
  const targetDoc = await targetDocRef.get();
  if (!targetDoc.exists) {
    throw new HttpsError('not-found', 'That user no longer exists.');
  }
  requireSameOrg(profile, targetDoc.data()?.['organizationId'], 'That user is not a member of your organization.');

  if (disabled) {
    await assertNotLastAdmin(profile.organizationId as string, uid, 'suspend');
  }

  await getAuth().updateUser(uid, { disabled });

  await logAudit({
    action: disabled ? 'user.disable' : 'user.enable',
    actor: profile,
    organizationId: profile.organizationId,
    target: uid,
  });

  return { uid, disabled };
});

// Resends the welcome email (see email.ts) for an account that hasn't set
// a password yet — recovers a lost/bounced invite without recreating the
// account (which would fail anyway: the email already exists in Auth).
// Refuses once a password is set, same guard setInitialPassword itself
// applies, since resending at that point would be misleading — the
// account isn't waiting on this anymore.
export const resendInvite = onCall<ResendInviteRequest>({ region: REGION, secrets: [RESEND_API_KEY] }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can resend invites.');

  const { uid } = request.data;
  if (!uid) {
    throw new HttpsError('invalid-argument', 'A uid is required.');
  }

  const targetDocRef = getFirestore().collection('users').doc(uid);
  const targetDoc = await targetDocRef.get();
  if (!targetDoc.exists) {
    throw new HttpsError('not-found', 'That user no longer exists.');
  }
  const targetData = targetDoc.data() ?? {};
  requireSameOrg(profile, targetData['organizationId'], 'That user is not a member of your organization.');

  const authUser = await getAuth().getUser(uid);
  const hasPassword = authUser.providerData.some((provider) => provider.providerId === 'password');
  if (hasPassword) {
    throw new HttpsError('failed-precondition', 'This account already has a password set.');
  }

  const roles: unknown[] = Array.isArray(targetData['role']) ? targetData['role'] : [];
  const assignableRole = roles.find((role): role is AssignableRole => ASSIGNABLE_ROLES.includes(role as AssignableRole));
  if (!assignableRole) {
    throw new HttpsError(
      'failed-precondition',
      "This user has no ems/physician/nurse role to base the invite's app link on.",
    );
  }

  await sendWelcomeEmail({ email: targetData['email'], firstName: targetData['firstName'], role: assignableRole });

  await logAudit({
    action: 'user.resendInvite',
    actor: profile,
    organizationId: profile.organizationId,
    target: uid,
  });

  return { uid };
});

// Firebase Auth has no organization concept, so listUsers(1000) (the old
// implementation) can only ever return the whole project regardless of org —
// this queries Firestore's own users collection instead, which both scopes
// the result to the caller's org and drops the old hard 1000-user,
// no-pagination cap that came from misusing the Auth Admin API for this.
//
// disabled/hasPassword aren't in Firestore at all (Auth-only properties) —
// getUsers() batch-fetches every org member's Auth record in one call
// rather than one getUser() per row, so the table can show account status
// without an N-request fan-out.
export const listUsersWithRoles = onCall({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can list users.');

  const profileDocs = await getFirestore()
    .collection('users')
    .where('organizationId', '==', profile.organizationId)
    .get();

  const uids = profileDocs.docs.map((docSnapshot) => docSnapshot.id);
  const authByUid = new Map<string, { disabled: boolean; hasPassword: boolean }>();
  if (uids.length > 0) {
    const { users: authUsers } = await getAuth().getUsers(uids.map((uid) => ({ uid })));
    for (const authUser of authUsers) {
      authByUid.set(authUser.uid, {
        disabled: authUser.disabled,
        hasPassword: authUser.providerData.some((provider) => provider.providerId === 'password'),
      });
    }
  }

  return profileDocs.docs.map((docSnapshot) => {
    const data = docSnapshot.data();
    const roles = data['role'];
    const authInfo = authByUid.get(docSnapshot.id);
    return {
      uid: docSnapshot.id,
      email: data['email'] ?? '',
      firstName: data['firstName'] ?? '',
      lastName: data['lastName'] ?? '',
      role: Array.isArray(roles) ? roles : [],
      disabled: authInfo?.disabled ?? false,
      hasPassword: authInfo?.hasPassword ?? false,
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

    await logAudit({
      action: 'hospital.create',
      actor: profile,
      organizationId: profile.organizationId,
      target: docRef.id,
      details: { name, address },
    });

    return { id: docRef.id, name, address, latitude, longitude };
  },
);

// Re-geocodes if the address changes (same helper createHospital uses) —
// lat/lng have to stay in sync with the displayed address, not just the
// text itself, since the physician app's distance-sort feature reads
// those coordinates directly.
export const updateHospital = onCall<UpdateHospitalRequest>(
  { region: REGION, secrets: [GEOCODING_API_KEY] },
  async (request) => {
    const profile = await getCallerProfile(request.auth?.uid);
    requireAdmin(profile, 'Only admins can edit hospitals.');

    const { hospitalId, name, address } = request.data;
    if (!hospitalId || (!name && !address)) {
      throw new HttpsError('invalid-argument', 'A hospitalId and at least one of name or address are required.');
    }

    const hospitalRef = getFirestore().collection('hospitals').doc(hospitalId);
    const hospitalDoc = await hospitalRef.get();
    if (!hospitalDoc.exists) {
      throw new HttpsError('not-found', 'That hospital no longer exists.');
    }
    const hospitalData = hospitalDoc.data() ?? {};
    requireSameOrg(profile, hospitalData['organizationId'], 'That hospital belongs to a different organization.');

    const update: Record<string, string | number> = {};
    if (name) update['name'] = name;
    if (address) {
      const { latitude, longitude } = await geocodeAddress(address);
      update['address'] = address;
      update['latitude'] = latitude;
      update['longitude'] = longitude;
    }

    await hospitalRef.update(update);

    await logAudit({
      action: 'hospital.update',
      actor: profile,
      organizationId: profile.organizationId,
      target: hospitalId,
      details: { name: update['name'], address: update['address'] },
    });

    return {
      id: hospitalId,
      name: update['name'] ?? hospitalData['name'] ?? '',
      address: update['address'] ?? hospitalData['address'] ?? '',
      latitude: update['latitude'] ?? hospitalData['latitude'] ?? 0,
      longitude: update['longitude'] ?? hospitalData['longitude'] ?? 0,
    };
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
  const hospitalData = hospitalDoc.data() ?? {};
  requireSameOrg(profile, hospitalData['organizationId'], 'That hospital belongs to a different organization.');

  await hospitalRef.delete();

  await logAudit({
    action: 'hospital.delete',
    actor: profile,
    organizationId: profile.organizationId,
    target: hospitalId,
    details: { name: hospitalData['name'] },
  });

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

  const { organizationName, adminEmail, adminFirstName, adminLastName, country } = request.data;
  const validCountries = ['CA', 'US', 'GB', 'AU', 'OTHER'];
  if (!organizationName || !adminEmail || !adminFirstName || !adminLastName || !validCountries.includes(country)) {
    throw new HttpsError(
      'invalid-argument',
      'An organization name, country, and the first admin\'s email, first name, and last name are required.',
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
    .add({ name: organizationName, country, createdAt: FieldValue.serverTimestamp(), createdBy: request.auth?.uid });

  await getFirestore().collection('users').doc(newAdmin.uid).set({
    email: adminEmail,
    firstName: adminFirstName,
    lastName: adminLastName,
    role: ['admin'],
    organizationId: orgRef.id,
  });

  // organizationId is the new org, not profile.organizationId — the caller
  // is a super-admin, who has no organizationId of their own.
  await logAudit({
    action: 'organization.create',
    actor: profile,
    organizationId: orgRef.id,
    target: newAdmin.uid,
    details: { organizationName, adminEmail, country },
  });

  return {
    organizationId: orgRef.id,
    organizationName,
    adminUid: newAdmin.uid,
    adminEmail,
    country,
  };
});

// organizations/{orgId} is Admin-SDK-write-only (see firestore.rules), so
// an org-admin needs this to flip their own org's retention setting —
// requireAdmin already confirms the caller has an organizationId, so
// there's no way to target any org but the caller's own.
export const setOrganizationRetention = onCall<SetOrganizationRetentionRequest>(
  { region: REGION },
  async (request) => {
    const profile = await getCallerProfile(request.auth?.uid);
    requireAdmin(profile, 'Only admins can change data retention settings.');

    const { retainAllData } = request.data;
    if (typeof retainAllData !== 'boolean') {
      throw new HttpsError('invalid-argument', 'retainAllData must be a boolean.');
    }

    await getFirestore().collection('organizations').doc(profile.organizationId as string).update({ retainAllData });

    await logAudit({
      action: 'organization.setRetention',
      actor: profile,
      organizationId: profile.organizationId,
      details: { retainAllData },
    });

    return { retainAllData };
  },
);

// Lets an org's own admin set/correct their org's country — country is
// required at createOrganization time now, but every org created before
// this feature shipped has none, and this is how those get backfilled
// (rather than a one-off migration script) without needing super-admin
// involvement each time.
export const setOrganizationCountry = onCall<SetOrganizationCountryRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can change organization settings.');

  const { country } = request.data;
  const validCountries = ['CA', 'US', 'GB', 'AU', 'OTHER'];
  if (!validCountries.includes(country)) {
    throw new HttpsError('invalid-argument', `country must be one of: ${validCountries.join(', ')}.`);
  }

  await getFirestore().collection('organizations').doc(profile.organizationId as string).update({ country });

  await logAudit({
    action: 'organization.setCountry',
    actor: profile,
    organizationId: profile.organizationId,
    details: { country },
  });

  return { country };
});

// Turns Canada-based Cloud KMS data residency on/off for the caller's org.
// Firestore's own CMEK applies to a whole database and can only be set at
// creation time, so it can't be toggled per-org on the shared database
// this app runs on — instead, patient.name/healthcareNumber get
// application-level envelope encryption (see kms.ts/patients.ts) gated on
// this flag, with a dedicated Cloud KMS key created per org on first
// opt-in. Restricted to orgs with country 'CA' — the whole point of the
// flag — checked server-side even though the client UI already gates on
// this, since a client-side gate alone isn't a real guarantee.
export const setOrganizationCmekPreference = onCall<SetOrganizationCmekRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can change organization settings.');

  const { cmekRequested } = request.data;
  if (typeof cmekRequested !== 'boolean') {
    throw new HttpsError('invalid-argument', 'cmekRequested must be a boolean.');
  }

  const orgRef = getFirestore().collection('organizations').doc(profile.organizationId as string);
  const update: Record<string, unknown> = { cmekRequested };

  if (cmekRequested) {
    const orgDoc = await orgRef.get();
    if (orgDoc.data()?.['country'] !== 'CA') {
      throw new HttpsError(
        'failed-precondition',
        'Canadian data residency can only be requested for organizations with country set to Canada.',
      );
    }

    // Idempotent — a re-toggle (off then on) reuses the same org key
    // rather than minting a new one every time.
    try {
      update['kmsKeyName'] = await getOrCreateOrgKey(profile.organizationId as string);
    } catch (error) {
      logger.error('Failed to provision the Cloud KMS key for organization', { organizationId: profile.organizationId, error });
      throw new HttpsError(
        'internal',
        "Couldn't set up the encryption key for this organization. This usually means the Cloud KMS key ring " +
          "hasn't been provisioned yet — contact support before retrying.",
      );
    }
  }

  await orgRef.update(update);

  await logAudit({
    action: 'organization.setCmekPreference',
    actor: profile,
    organizationId: profile.organizationId,
    details: { cmekRequested },
  });

  return { cmekRequested };
});

// Returns the caller's org's most recent audit entries — admin.ts's own
// mutations only (createUser/updateUser/deleteUser/setUserDisabled/
// resendInvite/setUserRole/removeUserRole/createHospital/updateHospital/
// deleteHospital/createOrganization/setOrganizationRetention/
// setOrganizationCountry/setOrganizationCmekPreference); EMS/physician
// actions aren't logged here. No client ever reads the auditLog
// collection directly (see firestore.rules) — this is the only read
// path, same pattern as listUsersWithRoles.
export const listAuditLog = onCall({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  requireAdmin(profile, 'Only admins can view the audit log.');

  const snapshot = await getFirestore()
    .collection('auditLog')
    .where('organizationId', '==', profile.organizationId)
    .orderBy('timestamp', 'desc')
    .limit(100)
    .get();

  return snapshot.docs.map((docSnapshot) => {
    const data = docSnapshot.data();
    const timestamp = data['timestamp'];
    return {
      id: docSnapshot.id,
      action: data['action'] ?? '',
      actorEmail: data['actorEmail'] ?? '',
      target: data['target'] ?? null,
      details: data['details'] ?? null,
      timestampMs: timestamp instanceof Timestamp ? timestamp.toMillis() : null,
    };
  });
});

const RETENTION_MS = 48 * 60 * 60 * 1000;

// Deletes a completed patient's record 48h after completeTransport()
// (apps/ems's patient-upload.service.ts) marked it done — unless the
// patient's org has turned on "retain all data" via setOrganizationRetention
// above, in which case that org's completed patients are skipped entirely.
// The sibling emsLocations doc isn't deleted here directly; ems.ts's
// onPatientDeleted trigger fires off this delete and cleans it up.
//
// Cloud Scheduler (which onSchedule provisions under the hood) doesn't
// support northamerica-northeast2 (Toronto), unlike every other function
// here — northamerica-northeast1 (Montreal) is the nearest region that
// does. This is purely where the schedule trigger + function execute; the
// Firestore reads/deletes below still target the same (default) database
// regardless, at the cost of one extra region hop for a function that only
// ever runs once a day in the background.
export const cleanupCompletedPatients = onSchedule(
  { schedule: 'every 24 hours', region: 'northamerica-northeast1' },
  async () => {
    const cutoff = Timestamp.fromMillis(Date.now() - RETENTION_MS);

    const orgsSnapshot = await getFirestore().collection('organizations').get();
    const retainAllOrgIds = new Set(
      orgsSnapshot.docs.filter((orgDoc) => orgDoc.data()['retainAllData'] === true).map((orgDoc) => orgDoc.id),
    );

    const completedSnapshot = await getFirestore()
      .collection('patients')
      .where('status', '==', 'completed')
      .where('completedAt', '<=', cutoff)
      .get();

    const writer = getFirestore().bulkWriter();
    for (const patientDoc of completedSnapshot.docs) {
      if (retainAllOrgIds.has(patientDoc.data()['organizationId'])) {
        continue;
      }
      writer.delete(patientDoc.ref);
    }
    await writer.close();
  },
);
