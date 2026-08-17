import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
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
    required this.latitude,
    required this.longitude,
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
  final double? latitude;
  final double? longitude;
  final String ivSize;
  final String ivPlacement;
  final String treatment;
  final String notes;
}

const _optionalTopLevelFields = ['location', 'ivSize', 'ivPlacement', 'treatment'];

/// The literal blank-field sentinel EMS writes when name/healthcareNumber
/// are left empty — shared so `patient_upload_screen.dart` can resolve a
/// just-saved value identically when seeding the decrypt cache (see
/// `_onSubmit`), rather than duplicating this rule and risking drift.
String resolveBlankField(String value) => value.isNotEmpty ? value : 'Unknown';

/// Mirrors `apps/ems/src/app/services/patient-upload.service.ts`: direct
/// Firestore writes to `patients` (no Cloud Function — EMS accounts write
/// this collection directly, per firestore.rules). The one exception is
/// `name`/`healthcareNumber`, which are always routed through
/// `encryptPatientFields` (functions/src/patients.ts) first — that
/// function itself decides encrypt-vs-passthrough from the caller's org,
/// so this call site never branches on whether Canadian data residency is
/// even on for the current org.
class PatientUploadService {
  PatientUploadService(this._firestore, this._functions);

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  Future<Map<String, Object?>> _patientFields(PatientFormValues value) async {
    final hasLocation = value.latitude != null && value.longitude != null;

    final name = resolveBlankField(value.name);
    final healthcareNumber = resolveBlankField(value.healthcareNumber);

    // Deliberately never falls back to writing the plaintext values above
    // on failure — that would make Canadian data residency fail silently
    // exactly when a flaky connection makes it most likely to fail. Lets
    // the exception propagate; uploadPatient/updatePatient's callers
    // already surface any failure here as a blocking, retryable error and
    // stay on the form rather than navigating away.
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
      throw PatientFieldEncryptionException(error);
    }

    return {
      'name': encryptedName,
      'gender': value.gender.isNotEmpty ? value.gender : 'Unknown',
      'age': value.age ?? 'Unknown',
      'healthcareNumber': encryptedHealthcareNumber,
      'destination': value.destination.isNotEmpty ? value.destination : 'Unknown',
      'vitals': {
        'heartRate': value.heartRate ?? 'Unknown',
        'bloodPressure': value.bloodPressure.isNotEmpty ? value.bloodPressure : 'Unknown',
        'oxygen': value.oxygen ?? 'Unknown',
        'temperature': value.temperature ?? 'Unknown',
        if (value.respiratoryRate != null) 'respiratoryRate': value.respiratoryRate,
        if (value.gcs != null) 'gcs': value.gcs,
      },
      if (hasLocation)
        'location': {'latitude': value.latitude, 'longitude': value.longitude, 'address': ''},
      if (value.ivSize.isNotEmpty) 'ivSize': value.ivSize,
      if (value.ivPlacement.isNotEmpty) 'ivPlacement': value.ivPlacement,
      if (value.treatment.isNotEmpty) 'treatment': value.treatment,
      'notes': value.notes,
    };
  }

  // Diagnostic only, not console/print-based (which relays over the DWDS
  // debug websocket and could itself drop messages under load — not
  // trustworthy evidence). A test can read this directly, in-process, for
  // an unambiguous count of real Dart-level invocations regardless of
  // console relay reliability.
  static int debugCallCount = 0;
  static final List<StackTrace> debugCallStacks = [];

  Future<String> uploadPatient(PatientFormValues value, String organizationId) async {
    debugCallCount++;
    debugCallStacks.add(StackTrace.current);

    final fields = await _patientFields(value);
    final docRef = await _firestore.collection('patients').add({
      ...fields,
      // Stamped from the caller's own org, never client-chosen — matches
      // firestore.rules' create check.
      'organizationId': organizationId,
      'submittedAt': FieldValue.serverTimestamp(),
      'status': 'active',
    });
    return docRef.id;
  }

  // updateDoc only touches fields present in the map — a field the form
  // left blank (because the EMS user cleared it) needs an explicit
  // FieldValue.delete() or it's silently left at its previous value.
  // organizationId is deliberately never included — rules block changing
  // it post-create.
  Future<void> updatePatient(String id, PatientFormValues value) async {
    final fields = await _patientFields(value);
    final update = <String, Object?>{...fields, 'updatedAt': FieldValue.serverTimestamp()};
    for (final field in _optionalTopLevelFields) {
      if (!fields.containsKey(field)) {
        update[field] = FieldValue.delete();
      }
    }
    await _firestore.collection('patients').doc(id).update(update);
  }

  Future<void> deletePatient(String id) {
    return _firestore.collection('patients').doc(id).delete();
  }

  Future<void> completeTransport(String id) {
    return _firestore.collection('patients').doc(id).update({
      'status': 'completed',
      'completedAt': FieldValue.serverTimestamp(),
    });
  }
}

/// Thrown when `encryptPatientFields` fails — deliberately never caught
/// and silently degraded to a plaintext write (see `_patientFields`'s own
/// comment). The upload/edit screen's existing generic error handling
/// already surfaces this as a blocking, retryable error and keeps the
/// user on the form rather than navigating away.
class PatientFieldEncryptionException implements Exception {
  PatientFieldEncryptionException(this.cause);

  final Object cause;

  @override
  String toString() => 'Failed to prepare patient fields for saving: $cause';
}

final patientUploadServiceProvider = Provider<PatientUploadService>((ref) {
  return PatientUploadService(
    FirebaseFirestore.instance,
    FirebaseFunctions.instanceFor(region: _functionsRegion),
  );
});
