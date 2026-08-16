import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { getFirestore } from 'firebase-admin/firestore';
import { DecryptPatientFieldsRequest } from './classes/decrypt-patient-fields-request';
import { EncryptPatientFieldsRequest } from './classes/encrypt-patient-fields-request';
import { REGION, getCallerProfile } from './shared';
import { decryptField, encryptField, isEncryptedField } from './kms';

// EMS calls this before every direct Firestore write to `patients` (see
// flutter/apps/ems/lib/services/patient_upload_service.dart — EMS still
// writes patients directly, this is the one server round trip inserted
// ahead of that write). The function itself decides encrypt-vs-passthrough
// from the caller's own org's `cmekRequested` — never a client-supplied
// flag — which is what actually prevents a client from choosing to skip
// encryption for an opted-in org. firestore.rules' fieldsRespectCmek check
// closes the other half of that gap at the database level.
export const encryptPatientFields = onCall<EncryptPatientFieldsRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  if (!profile.role.includes('ems')) {
    throw new HttpsError('permission-denied', 'Only EMS accounts can prepare patient fields.');
  }
  if (!profile.organizationId) {
    throw new HttpsError('failed-precondition', 'Your account is not part of an organization.');
  }

  const { name, healthcareNumber } = request.data;
  if (typeof name !== 'string' || typeof healthcareNumber !== 'string') {
    throw new HttpsError('invalid-argument', 'name and healthcareNumber (strings) are required.');
  }

  const orgDoc = await getFirestore().collection('organizations').doc(profile.organizationId).get();
  if (orgDoc.data()?.['cmekRequested'] !== true) {
    return { name, healthcareNumber };
  }

  const keyName = orgDoc.data()?.['kmsKeyName'];
  if (typeof keyName !== 'string') {
    // Shouldn't happen — setOrganizationCmekPreference always provisions a
    // key before it lets cmekRequested flip true — but fail loudly rather
    // than silently writing plaintext if it somehow does.
    throw new HttpsError(
      'failed-precondition',
      "This organization has Canadian data residency requested but its encryption key isn't set up yet.",
    );
  }

  const [encryptedName, encryptedHealthcareNumber] = await Promise.all([
    encryptField(name, keyName),
    encryptField(healthcareNumber, keyName),
  ]);

  return { name: encryptedName, healthcareNumber: encryptedHealthcareNumber };
});

// Pull-based read path for physician/EMS, batched to avoid an
// N-round-trip fan-out on a list screen. Same-org authorization mirrors
// firestore.rules' own `patients` read rule (isSuperAdmin() ||
// sameOrgAsCaller(...)). Fields that aren't actually encrypted (a plain
// legacy string, or an org that never opted in) pass straight through, so
// callers never need to branch on whether encryption is even on for a
// given patient — this is always safe to call.
export const decryptPatientFields = onCall<DecryptPatientFieldsRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);

  const { patientIds } = request.data;
  if (!Array.isArray(patientIds) || patientIds.length === 0) {
    throw new HttpsError('invalid-argument', 'patientIds (a non-empty array) is required.');
  }

  const isSuperAdmin = profile.role.includes('super-admin');

  const results = await Promise.all(
    patientIds.map(async (patientId) => {
      const doc = await getFirestore().collection('patients').doc(patientId).get();
      const data = doc.data();
      // Same shape for "doesn't exist" and "exists but wrong org" —
      // deliberately doesn't reveal which, so this can't be used to probe
      // whether a patient id from another org exists at all.
      if (!doc.exists || !data || (!isSuperAdmin && data['organizationId'] !== profile.organizationId)) {
        return { patientId, name: null, healthcareNumber: null };
      }

      const [name, healthcareNumber] = await Promise.all([
        resolveField(data['name']),
        resolveField(data['healthcareNumber']),
      ]);
      return { patientId, name, healthcareNumber };
    }),
  );

  return { results };
});

async function resolveField(value: unknown): Promise<string | null> {
  if (typeof value === 'string') return value;
  if (isEncryptedField(value)) return decryptField(value);
  return null;
}
