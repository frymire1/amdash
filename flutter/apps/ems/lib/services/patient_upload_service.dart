import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Must match REGION in functions/src/shared.ts.
const _functionsRegion = 'northamerica-northeast2';

/// Raw values straight off the upload form — mirrors the shape
/// `patientForm.getRawValue()` produces in
/// `apps/ems/src/app/components/patient-upload/patient-upload.component.ts`.
/// Blank/unset fields are resolved to Firestore's `'Unknown'` sentinel (or
/// omitted, for genuinely optional fields) by [PatientUploadService], not
/// here — this class just carries what the form actually holds.
class PatientFormValues {
  const PatientFormValues({
    required this.name,
    required this.gender,
    required this.age,
    required this.healthcareNumber,
    required this.destination,
    required this.heartRate,
    required this.bloodPressure,
    required this.oxygen,
    required this.temperature,
    required this.respiratoryRate,
    required this.gcs,
    required this.ivSize,
    required this.ivPlacement,
    required this.treatment,
    required this.notes,
  });

  final String name;
  final String gender;
  final num? age;
  final String healthcareNumber;
  final String destination;
  final num? heartRate;
  final String bloodPressure;
  final num? oxygen;
  final num? temperature;
  final int? respiratoryRate;
  final int? gcs;
  final String ivSize;
  final String ivPlacement;
  final String treatment;
  final String notes;
}

const _optionalTopLevelFields = ['ivSize', 'ivPlacement', 'treatment'];

/// The literal blank-field sentinel EMS writes when name/healthcareNumber
/// are left empty — shared so `patient_upload_screen.dart` can resolve a
/// just-saved value identically when seeding the decrypt cache (see
/// `_onSubmit`), rather than duplicating this rule and risking drift.
String resolveBlankField(String value) => value.isNotEmpty ? value : 'Unknown';

/// The `ciphertext` off an `EncryptedField` blob (see
/// `functions/src/kms.ts`) as written by `encryptPatientFields` — null for
/// a plain (non-CMEK) org, where `field` is just a `String`. This is what
/// `patient_upload_screen.dart` seeds into the decrypt cache alongside the
/// just-saved plaintext, so a later read from a fresh `Patient` snapshot
/// (carrying this same ciphertext) recognizes the cached value as current
/// rather than treating it as stale — see `PatientField.fingerprint`.
String? _fingerprintOf(Object? field) {
  return field is Map ? field['ciphertext'] as String? : null;
}

/// `uploadPatient`/`updatePatient`'s return value: the patient id plus
/// enough to seed `amdash_core`'s decrypt cache with a fingerprint that
/// actually matches what was just written (see `_fingerprintOf`).
class PatientSaveResult {
  const PatientSaveResult({required this.id, this.nameFingerprint, this.healthcareNumberFingerprint});

  final String id;
  final String? nameFingerprint;
  final String? healthcareNumberFingerprint;
}

/// Mirrors `apps/ems/src/app/services/patient-upload.service.ts`.
/// `updatePatient`/`completeTransport` are direct Firestore writes to
/// `patients` (EMS accounts write this collection directly, per
/// firestore.rules — kept that way so an ambulance with spotty
/// connectivity gets offline queueing for free from the Firestore client
/// SDK); `updatePatient` routes name/healthcareNumber through
/// `encryptPatientFields` (functions/src/patients.ts) first, which itself
/// decides encrypt-vs-passthrough from the caller's org, so this call site
/// never branches on whether Canadian data residency is even on for the
/// current org. `uploadPatient`/`deletePatient` are callables instead —
/// see each one's own doc comment for why.
///
/// Every write also stamps `createdBy`/`updatedBy` with the signed-in
/// user's uid (enforced by firestore.rules for the direct writes, by
/// `request.auth` server-side for the callables) — the only way the
/// server-side onPatientCreated/onPatientUpdated audit triggers can
/// attribute a write to a real person.
class PatientUploadService {
  PatientUploadService(this._firestore, this._functions, this._auth);

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;

  // The 'Unknown'-defaulting/optional-field-omission shape shared by both
  // create and update — everything except name/healthcareNumber (create
  // encrypts them server-side inline; update encrypts them via
  // encryptPatientFields first, see _updateFields below) and location
  // (create-only, seeded through uploadPatientDocument itself — a
  // patient's GPS position is never persisted as its own field, on the
  // patient doc or otherwise; see that function's own doc comment for
  // where it actually lives).
  Map<String, Object?> _sharedFields(PatientFormValues value) {
    return {
      'gender': value.gender.isNotEmpty ? value.gender : 'Unknown',
      'age': value.age ?? 'Unknown',
      'destination': value.destination.isNotEmpty ? value.destination : 'Unknown',
      'vitals': {
        'heartRate': value.heartRate ?? 'Unknown',
        'bloodPressure': value.bloodPressure.isNotEmpty ? value.bloodPressure : 'Unknown',
        'oxygen': value.oxygen ?? 'Unknown',
        'temperature': value.temperature ?? 'Unknown',
        if (value.respiratoryRate != null) 'respiratoryRate': value.respiratoryRate,
        if (value.gcs != null) 'gcs': value.gcs,
      },
      if (value.ivSize.isNotEmpty) 'ivSize': value.ivSize,
      if (value.ivPlacement.isNotEmpty) 'ivPlacement': value.ivPlacement,
      if (value.treatment.isNotEmpty) 'treatment': value.treatment,
      'notes': value.notes,
    };
  }

  // Only ever used by updatePatient — encrypts name/healthcareNumber via
  // encryptPatientFields (a separate round trip ahead of the direct
  // Firestore write updatePatient itself performs). uploadPatient doesn't
  // call this: uploadPatientDocument encrypts inline as part of creating
  // the document, in the same call.
  //
  // Deliberately never falls back to writing the plaintext values on
  // failure — that would make Canadian data residency fail silently
  // exactly when a flaky connection makes it most likely to fail. Lets the
  // exception propagate; updatePatient's caller already surfaces any
  // failure here as a blocking, retryable error and stays on the form
  // rather than navigating away.
  Future<Map<String, Object?>> _updateFields(PatientFormValues value) async {
    final name = resolveBlankField(value.name);
    final healthcareNumber = resolveBlankField(value.healthcareNumber);

    final Object? encryptedName;
    final Object? encryptedHealthcareNumber;
    try {
      final callable = _functions.httpsCallable('encryptPatientFields');
      final result = await callable.call<Map<Object?, Object?>>({
        'name': name,
        'healthcareNumber': healthcareNumber,
      });
      encryptedName = result.data['name'];
      encryptedHealthcareNumber = result.data['healthcareNumber'];
    } catch (error) {
      throw PatientSaveException(error);
    }

    return {'name': encryptedName, 'healthcareNumber': encryptedHealthcareNumber, ..._sharedFields(value)};
  }

  // Diagnostic only, not console/print-based (which relays over the DWDS
  // debug websocket and could itself drop messages under load — not
  // trustworthy evidence). A test can read this directly, in-process, for
  // an unambiguous count of real Dart-level invocations regardless of
  // console relay reliability.
  static int debugCallCount = 0;
  static final List<StackTrace> debugCallStacks = [];

  // Unlike every other write here, this is not a direct Firestore write —
  // firestore.rules flatly blocks a direct client create now (see its own
  // comment) because creation has to atomically seed this patient's
  // initial location subdocument too, which only a Cloud Function can do.
  // organizationId isn't a parameter here for that reason: unlike the old
  // direct write, uploadPatientDocument derives it itself from the
  // caller's own profile, never a client-supplied value. [latitude]/
  // [longitude] are the EMS device's GPS fix at the moment of upload, if
  // "live-track this patient" is on and a fix was obtained — omit both to
  // create a patient with no known location at all (matches live tracking
  // being off).
  //
  // The real cost of routing through a callable: no offline queueing for
  // this specific write, unlike every other one here — see
  // uploadPatientDocument's own doc comment. patient_upload_screen.dart
  // shows an OfflineBanner so EMS sees this coming before they submit.
  Future<PatientSaveResult> uploadPatient(PatientFormValues value, {double? latitude, double? longitude}) async {
    debugCallCount++;
    debugCallStacks.add(StackTrace.current);

    final name = resolveBlankField(value.name);
    final healthcareNumber = resolveBlankField(value.healthcareNumber);

    final Map<Object?, Object?> data;
    try {
      final callable = _functions.httpsCallable('uploadPatientDocument');
      final result = await callable.call<Map<Object?, Object?>>({
        'name': name,
        'healthcareNumber': healthcareNumber,
        ..._sharedFields(value),
        if (latitude != null && longitude != null) 'latitude': latitude,
        if (latitude != null && longitude != null) 'longitude': longitude,
      });
      data = result.data;
    } catch (error) {
      throw PatientSaveException(error);
    }

    return PatientSaveResult(
      id: data['id'] as String,
      nameFingerprint: _fingerprintOf(data['name']),
      healthcareNumberFingerprint: _fingerprintOf(data['healthcareNumber']),
    );
  }

  // updateDoc only touches fields present in the map — a field the form
  // left blank (because the EMS user cleared it) needs an explicit
  // FieldValue.delete() or it's silently left at its previous value.
  // organizationId is deliberately never included — rules block changing
  // it post-create; createdBy is the same story, immutable once written.
  Future<PatientSaveResult> updatePatient(String id, PatientFormValues value) async {
    final fields = await _updateFields(value);
    final update = <String, Object?>{
      ...fields,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': _auth.currentUser?.uid,
    };
    for (final field in _optionalTopLevelFields) {
      if (!fields.containsKey(field)) {
        update[field] = FieldValue.delete();
      }
    }
    await _firestore.collection('patients').doc(id).update(update);
    return PatientSaveResult(
      id: id,
      nameFingerprint: _fingerprintOf(fields['name']),
      healthcareNumberFingerprint: _fingerprintOf(fields['healthcareNumber']),
    );
  }

  // Routed through a Cloud Function rather than EMS's usual direct
  // Firestore write (see this class's own doc comment) — deleting a PHI
  // record is compliance-sensitive enough that firestore.rules flatly
  // blocks a direct client delete, so every deletion gets a guaranteed
  // request.auth-backed audit entry (functions/src/patients.ts's
  // deletePatientRecord) instead of one inferred from a trigger.
  Future<void> deletePatient(String id) async {
    await _functions.httpsCallable('deletePatientRecord').call<void>({'patientId': id});
  }

  Future<void> completeTransport(String id) {
    return _firestore.collection('patients').doc(id).update({
      'status': 'completed',
      'completedAt': FieldValue.serverTimestamp(),
      'updatedBy': _auth.currentUser?.uid,
    });
  }

  // Confirms completeTransport's own write via a real server round trip
  // (a `snapshots(includeMetadataChanges: true)` listener, not just a
  // one-off `get(GetOptions(source: Source.server))` — an earlier attempt
  // at this used that instead and it kept reporting the pre-completion
  // status well past when the write had actually landed) rather than
  // trusting the plain update()'s own Future alone. Most of the
  // "completeTransport's write never lands" symptoms chased while
  // building this turned out to actually be a *different* bug —
  // home_screen.dart's patient list building cards with no `key:`, which
  // let Flutter silently reuse this card's own State for a different
  // patient once the completed one dropped out of the active list,
  // making later code check the wrong patient's status entirely (see that
  // file's own comment) — not a real write-propagation delay. That bug is
  // fixed now, but this confirm-and-retry wrapper is kept as a real
  // safety net regardless: a direct client write's Future resolving
  // before the write is durably visible to a separate server-side read is
  // a documented category of Firestore behavior even when everything else
  // is correct, and re-issuing this identical, idempotent update is cheap
  // insurance against it.
  //
  // Throws [StateError] if every attempt fails to confirm — the caller
  // decides how to surface that (see patient_summary_card.dart's
  // _completeTransport).
  Future<void> completeTransportConfirmed(String id, {int maxAttempts = 3}) async {
    String? lastFailure;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      await completeTransport(id);
      lastFailure = await _waitForStatus(id, 'completed', const Duration(seconds: 6));
      if (lastFailure == null) return;
    }
    throw StateError("completeTransport didn't confirm after $maxAttempts attempts: $lastFailure");
  }

  // Returns the last status actually observed — null if it matched
  // [status] once server-acknowledged, otherwise whatever was last seen,
  // for callers that want to surface *why* this gave up.
  Future<String?> _waitForStatus(String id, String status, Duration timeout) async {
    Object? lastSeen;
    final stream = _firestore.collection('patients').doc(id).snapshots(includeMetadataChanges: true);
    try {
      await for (final snapshot in stream.timeout(timeout)) {
        if (snapshot.metadata.hasPendingWrites) continue;
        lastSeen = snapshot.exists ? (snapshot.data()?['status']) : 'NO_SUCH_DOC';
        if (lastSeen == status) return null;
      }
    } on TimeoutException {
      // Falls through to the "gave up" return below with whatever was
      // last observed (possibly still null, if no server-acknowledged
      // snapshot ever arrived at all).
    }
    return 'gave up, last observed status: $lastSeen';
  }
}

/// Thrown when either write path's server round trip fails — updatePatient's
/// call to `encryptPatientFields`, or uploadPatient's call to
/// `uploadPatientDocument`. Deliberately never caught and silently degraded
/// to a plaintext/unsaved write (see `_updateFields`'s own comment). The
/// upload/edit screen's existing generic error handling already surfaces
/// this as a blocking, retryable error and keeps the user on the form
/// rather than navigating away.
class PatientSaveException implements Exception {
  PatientSaveException(this.cause);

  final Object cause;

  @override
  String toString() => 'Failed to save this patient: $cause';
}

final patientUploadServiceProvider = Provider<PatientUploadService>((ref) {
  return PatientUploadService(
    FirebaseFirestore.instance,
    FirebaseFunctions.instanceFor(region: _functionsRegion),
    FirebaseAuth.instance,
  );
});
