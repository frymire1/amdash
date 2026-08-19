import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { onDocumentCreated, onDocumentUpdated } from 'firebase-functions/v2/firestore';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';
import { DecryptPatientFieldsRequest } from './classes/decrypt-patient-fields-request';
import { DeletePatientRecordRequest } from './classes/delete-patient-record-request';
import { EmsLocationEvent } from './classes/ems-location-event';
import { EncryptPatientFieldsRequest } from './classes/encrypt-patient-fields-request';
import { UploadPatientDocumentRequest } from './classes/upload-patient-document-request';
import { REGION, getCallerProfile, patientLocationRef } from './shared';
import { decryptField, encryptField, isEncryptedField } from './kms';
import { logAudit, resolveActor } from './audit';

// Shared by encryptPatientFields (below — EMS's own direct-write update
// path calls this first) and uploadPatientDocument (which encrypts inline
// as part of creating the document itself) — one place decides
// encrypt-vs-passthrough from the org's `cmekRequested` flag, rather than
// two copies that could drift.
async function encryptOrPassthroughFields(
  name: string,
  healthcareNumber: string,
  organizationId: string,
): Promise<{ name: string | object; healthcareNumber: string | object }> {
  const orgDoc = await getFirestore().collection('organizations').doc(organizationId).get();
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
}

// EMS calls this before every direct Firestore write that *updates* an
// existing patient (see flutter/apps/ems/lib/services/
// patient_upload_service.dart's updatePatient — edits stay a direct client
// write for offline queueing, so this is the one server round trip
// inserted ahead of that write). New patients go through
// uploadPatientDocument below instead, which encrypts inline rather than
// through this callable. firestore.rules' fieldsRespectCmek check closes
// the other half of the gap this exists for — a client can't skip calling
// this and write plaintext straight through for a CMEK-opted-in org.
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

  return encryptOrPassthroughFields(name, healthcareNumber, profile.organizationId);
});

// Creates a new patient record — unlike every other patient mutation, this
// one is *not* a direct client Firestore write (see updatePatient's own
// comment on why edits stay direct: offline queueing matters most for
// those, in-the-field). Routing creation through a callable is what makes
// it possible to atomically seed patients/{id}/location/current's very
// first fix in the same write as the patient doc itself (see the batch
// below) — firestore.rules flatly blocks a direct client write there, and
// the two documents need to become visible together, or functions/src/
// physician.ts's one-shot new-patient-alert ETA (which fires the instant
// the patient doc exists) would race a separate, slower publish chain.
// The real cost: this requires connectivity — no offline queueing for a
// brand-new patient the way EMS's other direct writes get. Accepted
// deliberately; flutter/apps/ems/lib/screens/patient_upload_screen.dart
// shows an OfflineBanner so EMS sees this coming before they even submit.
export const uploadPatientDocument = onCall<UploadPatientDocumentRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  if (!profile.role.includes('ems')) {
    throw new HttpsError('permission-denied', 'Only EMS accounts can create a patient record.');
  }
  if (!profile.organizationId) {
    throw new HttpsError('failed-precondition', 'Your account is not part of an organization.');
  }

  const { name, healthcareNumber, gender, age, destination, vitals, ivSize, ivPlacement, treatment, notes, latitude, longitude } =
    request.data;
  if (typeof name !== 'string' || typeof healthcareNumber !== 'string' || typeof vitals !== 'object' || vitals === null) {
    throw new HttpsError('invalid-argument', 'name, healthcareNumber, and vitals are required.');
  }

  const { name: encryptedName, healthcareNumber: encryptedHealthcareNumber } = await encryptOrPassthroughFields(
    name,
    healthcareNumber,
    profile.organizationId,
  );

  const firestore = getFirestore();
  const patientRef = firestore.collection('patients').doc();
  const batch = firestore.batch();

  batch.set(patientRef, {
    name: encryptedName,
    gender: gender || 'Unknown',
    age: age ?? 'Unknown',
    healthcareNumber: encryptedHealthcareNumber,
    destination: destination || 'Unknown',
    vitals,
    ...(ivSize ? { ivSize } : {}),
    ...(ivPlacement ? { ivPlacement } : {}),
    ...(treatment ? { treatment } : {}),
    notes: notes ?? '',
    organizationId: profile.organizationId,
    submittedAt: FieldValue.serverTimestamp(),
    status: 'active',
    createdBy: profile.uid,
    updatedBy: profile.uid,
  });

  const hasLocation = typeof latitude === 'number' && typeof longitude === 'number';
  if (hasLocation) {
    const event: EmsLocationEvent = {
      patientId: patientRef.id,
      organizationId: profile.organizationId,
      active: true,
      latitude,
      longitude,
    };
    batch.set(patientLocationRef(patientRef.id), { ...event, updatedAt: FieldValue.serverTimestamp() });
  }

  await batch.commit();

  return { id: patientRef.id, name: encryptedName, healthcareNumber: encryptedHealthcareNumber };
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

  // One entry per call, not per patient — this fires on every list
  // render/refresh that has anything un-cached or stale (see amdash_core's
  // pullMissingDecryptedPatientFields), so a patientId-per-entry log would
  // balloon for no real compliance benefit; "who pulled which patients'
  // identifying info, when" is fully answerable from this single entry.
  // Only patients this caller was actually authorized for get logged (the
  // not-found/wrong-org ones above already returned nulls without a real
  // decrypt) — cheap to recompute here since the map above already has it.
  const authorizedPatientIds = results.filter((r) => r.name !== null || r.healthcareNumber !== null).map((r) => r.patientId);
  if (authorizedPatientIds.length > 0) {
    await logAudit({
      action: 'patient.decrypt',
      actor: profile,
      organizationId: profile.organizationId,
      details: { patientIds: authorizedPatientIds, callerRole: profile.role.join(',') },
    });
  }

  return { results };
});

async function resolveField(value: unknown): Promise<string | null> {
  if (typeof value === 'string') return value;
  if (isEncryptedField(value)) return decryptField(value);
  return null;
}

// Another mutation routed through a callable rather than a direct client
// Firestore write (see uploadPatientDocument above for the other one;
// update/complete stay direct — offline queueing matters most for those,
// in-the-field). Deleting a PHI record is the single most
// compliance-sensitive thing this app does, so firestore.rules flatly
// blocks a direct client delete (`allow delete: if false`) and this is the
// only path left — giving every delete a guaranteed, unambiguous
// `request.auth`-backed audit entry, rather than inferring "who" from
// whatever the doc's own `updatedBy` last happened to say.
export const deletePatientRecord = onCall<DeletePatientRecordRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);
  if (!profile.role.includes('ems')) {
    throw new HttpsError('permission-denied', 'Only EMS accounts can delete a patient record.');
  }

  const { patientId } = request.data;
  if (!patientId) {
    throw new HttpsError('invalid-argument', 'patientId is required.');
  }

  const ref = getFirestore().collection('patients').doc(patientId);
  const snapshot = await ref.get();
  const organizationId = snapshot.data()?.['organizationId'];
  if (!snapshot.exists || typeof organizationId !== 'string') {
    throw new HttpsError('not-found', `No patient found with id ${patientId}.`);
  }
  if (organizationId !== profile.organizationId) {
    throw new HttpsError('permission-denied', 'That patient belongs to a different organization.');
  }

  await ref.delete();
  await logAudit({ action: 'patient.delete', actor: profile, organizationId, target: patientId });

  return { deleted: true };
});

// Audit-only — EMS writes patients directly from the Flutter client (see
// deletePatientRecord's comment for why create/update stay that way), so
// there's no callable/`request.auth` to attribute these to. Instead the
// client stamps `createdBy`/`updatedBy` (uids; firestore.rules enforces
// each equals the actual writer, so this can't be spoofed to frame another
// user), and resolveActor (audit.ts) turns that uid into the email the
// audit log displays.
export const onPatientCreated = onDocumentCreated({ document: 'patients/{patientId}', region: REGION }, async (event) => {
  const data = event.data?.data();
  if (!data) return;
  const organizationId = data['organizationId'];
  const actor = await resolveActor(data['createdBy']);
  await logAudit({
    action: 'patient.create',
    actor,
    organizationId: typeof organizationId === 'string' ? organizationId : undefined,
    target: event.params.patientId,
  });
});

// Distinguishes "marked transport complete" (apps/ems's completeTransport)
// from a regular field edit purely from the status transition — there's no
// separate signal for it in a plain document update, but this one is
// reliable: completeTransport is the only write that ever sets
// status: 'completed'.
export const onPatientUpdated = onDocumentUpdated({ document: 'patients/{patientId}', region: REGION }, async (event) => {
  const before = event.data?.before.data();
  const after = event.data?.after.data();
  if (!before || !after) return;
  const organizationId = after['organizationId'];
  const actor = await resolveActor(after['updatedBy']);
  const justCompleted = before['status'] !== 'completed' && after['status'] === 'completed';
  await logAudit({
    action: justCompleted ? 'patient.complete' : 'patient.update',
    actor,
    organizationId: typeof organizationId === 'string' ? organizationId : undefined,
    target: event.params.patientId,
  });
});
