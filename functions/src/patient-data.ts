import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { onDocumentCreated, onDocumentUpdated } from 'firebase-functions/v2/firestore';
import { FieldValue, Timestamp, getFirestore } from 'firebase-admin/firestore';
import { DecryptPatientFieldsRequest } from './classes/decrypt-patient-fields-request';
import { DeletePatientRecordRequest } from './classes/delete-patient-record-request';
import { EmsLocationEvent } from './classes/ems-location-event';
import { EncryptPatientFieldsRequest } from './classes/encrypt-patient-fields-request';
import { ExportPatientFhirBundleRequest } from './classes/export-patient-fhir-bundle-request';
import { UploadPatientDocumentRequest } from './classes/upload-patient-document-request';
import { VitalsHistoryEntry } from './classes/vitals-history-entry';
import { REGION, getCallerProfile } from './auth';
import { decryptField, encryptField, isEncryptedField } from './kms';
import { logAudit, resolveActor } from './audit';
import { FhirExportVitalsEntry, buildPatientFhirBundle } from './fhir';

// patients/{patientId}/location/current — the one place a patient's live
// GPS position lives (written by ems.ts's onEmsLocationEvent for every
// ongoing fix, and uploadPatientDocument below for the very first one). A
// subcollection rather than a field on the patient doc itself, and rather
// than its own top-level collection: a sibling document means every ~15s
// GPS tick never fires onPatientUpdated's audit trigger or re-emits the
// patients-collection listener the whole patient list watches (a Firestore
// subcollection write is invisible to both), while still living naturally
// alongside the patient it belongs to. Read org-wide via a
// collectionGroup('location') query (see EmsLocationController on the
// physician client) rather than a per-patient listener each.
export function patientLocationRef(patientId: string) {
  return getFirestore().collection('patients').doc(patientId).collection('location').doc('current');
}

// patients/{patientId}/vitalsHistory/{entryId} — an append-only log of
// every distinct vitals reading a patient has had, in the order EMS
// submitted them (see onPatientCreated/onPatientUpdated below, the only
// writers, and their own vitalsEqual/appendVitalsHistory). A subcollection
// for the same reason location is one — a sibling write never fires
// onPatientUpdated's own audit trigger or re-emits the patients-collection
// listener the whole patient list watches — plus this one is a genuine
// history (multiple documents, append-only), which couldn't be a single
// field on the patient doc regardless. Read per-patient, not org-wide like
// location, so this returns the whole collection rather than one fixed
// document.
export function patientVitalsHistoryCollection(patientId: string) {
  return getFirestore().collection('patients').doc(patientId).collection('vitalsHistory');
}

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

function toDateOrNull(value: unknown): Date | null {
  return value instanceof Timestamp ? value.toDate() : null;
}

// On-demand, not a background job triggered at completion — a completed
// record can still be corrected afterward (notes/treatment/destination
// edits stay possible; only vitals get history-tracked), and generating
// once at completion time would risk a silently stale export. Building
// the bundle fresh on every call means it always reflects whatever the
// record actually says right now.
//
// Not exportable until "not before completion, since the record isn't
// final until then" — `status === 'completed'` is the same signal
// onPatientUpdated's own `justCompleted` branch already keys off (the one
// write that ever sets it is EMS's completeTransport, see
// patient_upload_service.dart) — checked here as a hard precondition, not
// left to the client UI to enforce alone.
export const exportPatientFhirBundle = onCall<ExportPatientFhirBundleRequest>({ region: REGION }, async (request) => {
  const profile = await getCallerProfile(request.auth?.uid);

  const { patientId } = request.data;
  if (!patientId) {
    throw new HttpsError('invalid-argument', 'patientId is required.');
  }

  const isSuperAdmin = profile.role.includes('super-admin');
  const snapshot = await getFirestore().collection('patients').doc(patientId).get();
  const data = snapshot.data();
  // Same "don't reveal which" shape as decryptPatientFields — a
  // not-found and a wrong-org patientId look identical from the outside.
  if (!snapshot.exists || !data || (!isSuperAdmin && data['organizationId'] !== profile.organizationId)) {
    throw new HttpsError('not-found', `No patient found with id ${patientId}.`);
  }

  const organizationId = data['organizationId'];
  if (typeof organizationId !== 'string') {
    throw new HttpsError('failed-precondition', 'This patient has no organization on record.');
  }

  const orgDoc = await getFirestore().collection('organizations').doc(organizationId).get();
  if (orgDoc.data()?.['fhirExportEnabled'] !== true) {
    throw new HttpsError('failed-precondition', 'FHIR export is not enabled for this organization.');
  }

  if (data['status'] !== 'completed') {
    throw new HttpsError('failed-precondition', "This patient's transport must be marked complete before it can be exported.");
  }

  const [name, healthcareNumber] = await Promise.all([resolveField(data['name']), resolveField(data['healthcareNumber'])]);

  const historySnapshot = await patientVitalsHistoryCollection(patientId).orderBy('recordedAt', 'asc').get();
  const vitalsHistory: FhirExportVitalsEntry[] = historySnapshot.docs.map((doc) => {
    const entry = doc.data();
    return {
      heartRate: entry['heartRate'],
      bloodPressure: entry['bloodPressure'],
      oxygen: entry['oxygen'],
      temperature: entry['temperature'],
      respiratoryRate: typeof entry['respiratoryRate'] === 'number' ? entry['respiratoryRate'] : undefined,
      gcs: typeof entry['gcs'] === 'number' ? entry['gcs'] : undefined,
      recordedAt: toDateOrNull(entry['recordedAt']),
    };
  });

  const bundle = buildPatientFhirBundle(
    {
      name: name ?? 'Unknown',
      healthcareNumber: healthcareNumber ?? 'Unknown',
      gender: typeof data['gender'] === 'string' ? data['gender'] : 'Unknown',
      age: data['age'],
      destination: typeof data['destination'] === 'string' ? data['destination'] : 'Unknown',
      organizationName: typeof orgDoc.data()?.['name'] === 'string' ? (orgDoc.data()?.['name'] as string) : 'Unknown',
      treatment: typeof data['treatment'] === 'string' ? data['treatment'] : undefined,
      notes: typeof data['notes'] === 'string' ? data['notes'] : undefined,
      ivSize: typeof data['ivSize'] === 'string' ? data['ivSize'] : undefined,
      ivPlacement: typeof data['ivPlacement'] === 'string' ? data['ivPlacement'] : undefined,
      // The : 'active' fallback is provably unreachable, not an untested
      // gap: the precondition check above already required
      // data['status'] === 'completed' (a string) to get this far.
      /* v8 ignore next */
      status: typeof data['status'] === 'string' ? data['status'] : 'active',
      submittedAt: toDateOrNull(data['submittedAt']),
      completedAt: toDateOrNull(data['completedAt']),
    },
    vitalsHistory,
  );

  // A downloaded FHIR bundle is PHI leaving AmDash's own encryption/
  // access-control boundary entirely as a portable file — at least as
  // sensitive as patient.decrypt, so it's gated in audit.ts's
  // GATED_ACTIONS the same way.
  await logAudit({ action: 'patient.fhirExport', actor: profile, organizationId, target: patientId });

  return { bundle };
});

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

// Compares only the fields that actually make up a "vitals reading" —
// deliberately not a blind deep-equal over the whole vitals map, so a
// shape drift elsewhere (a field one side doesn't know about yet) can't
// silently suppress a real history entry. undefined counts as a value —
// EMS clearing a field (e.g. deleting a value they'd typed) is itself a
// real change worth a new history entry, same as any other edit.
const VITALS_HISTORY_FIELDS = ['heartRate', 'bloodPressure', 'oxygen', 'temperature', 'respiratoryRate', 'gcs'] as const;

function vitalsEqual(a: FirebaseFirestore.DocumentData | undefined, b: FirebaseFirestore.DocumentData | undefined): boolean {
  if (!a || !b) return a === b;
  return VITALS_HISTORY_FIELDS.every((field) => a[field] === b[field]);
}

// Appends one entry to patients/{patientId}/vitalsHistory — called from
// onPatientCreated (always, for the initial reading) and onPatientUpdated
// (only when vitalsEqual says something actually changed) below. Never
// called for a patient upload with no vitals object at all (shouldn't
// happen — the client always sends one — but this is a trigger, not a
// validated callable, so it can't assume the shape).
async function appendVitalsHistory(patientId: string, vitals: FirebaseFirestore.DocumentData, recordedBy: unknown): Promise<void> {
  const entry: VitalsHistoryEntry = {
    heartRate: vitals['heartRate'],
    bloodPressure: vitals['bloodPressure'],
    oxygen: vitals['oxygen'],
    temperature: vitals['temperature'],
    ...(typeof vitals['respiratoryRate'] === 'number' ? { respiratoryRate: vitals['respiratoryRate'] } : {}),
    ...(typeof vitals['gcs'] === 'number' ? { gcs: vitals['gcs'] } : {}),
    ...(typeof recordedBy === 'string' ? { recordedBy } : {}),
  };
  await patientVitalsHistoryCollection(patientId).add({ ...entry, recordedAt: FieldValue.serverTimestamp() });
}

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
  await Promise.all([
    logAudit({
      action: 'patient.create',
      actor,
      organizationId: typeof organizationId === 'string' ? organizationId : undefined,
      target: event.params.patientId,
    }),
    appendVitalsHistory(event.params.patientId, (data['vitals'] as FirebaseFirestore.DocumentData) ?? {}, data['createdBy']),
  ]);
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

  const tasks: Promise<unknown>[] = [
    logAudit({
      action: justCompleted ? 'patient.complete' : 'patient.update',
      actor,
      organizationId: typeof organizationId === 'string' ? organizationId : undefined,
      target: event.params.patientId,
    }),
  ];
  // Only a real change to vitals gets a new history entry — an edit that
  // only touched notes/treatment/destination/etc. shouldn't produce a
  // duplicate reading with a fresh timestamp.
  if (!vitalsEqual(before['vitals'] as FirebaseFirestore.DocumentData, after['vitals'] as FirebaseFirestore.DocumentData)) {
    tasks.push(appendVitalsHistory(event.params.patientId, (after['vitals'] as FirebaseFirestore.DocumentData) ?? {}, after['updatedBy']));
  }
  // A mid-transport reroute (EMS changes the destination hospital) has to
  // clear the *old* hospital's proximity-alert bookkeeping — otherwise
  // ems.ts's checkProximityAlertThresholds silently starves the *new*
  // hospital's physician of alerts it should get fresh. notifiedThresholds
  // is a flat "which minute-thresholds has this patient already crossed"
  // set with no awareness of which destination they were crossed for
  // (confirmed by reading that function directly): if the vehicle already
  // crossed 30/15 minutes on the way to hospital A, then reroutes to a
  // farther hospital B, `alreadyNotified` still has {30, 15} marked once
  // this patient gets close to B — those thresholds then never fire again
  // for B's physician, who could end up with only (at best) the 5-minute
  // alert, or none at all. The ETA calculation itself doesn't have this
  // bug (it already re-reads `destination` fresh on every check), only the
  // "have we already told someone" bookkeeping does.
  if (before['destination'] !== after['destination']) {
    tasks.push(
      patientLocationRef(event.params.patientId).set(
        { notifiedThresholds: FieldValue.delete(), lastEtaCheckAt: FieldValue.delete() },
        { merge: true },
      ),
    );
  }
  await Promise.all(tasks);
});
