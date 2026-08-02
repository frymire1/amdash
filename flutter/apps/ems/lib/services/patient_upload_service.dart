import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Mirrors `apps/ems/src/app/services/patient-upload.service.ts`: direct
/// Firestore writes to `patients` (no Cloud Function — EMS accounts write
/// this collection directly, per firestore.rules).
class PatientUploadService {
  PatientUploadService(this._firestore);

  final FirebaseFirestore _firestore;

  Map<String, Object?> _patientFields(PatientFormValues value) {
    final hasLocation = value.latitude != null && value.longitude != null;

    return {
      'name': value.name.isNotEmpty ? value.name : 'Unknown',
      'gender': value.gender.isNotEmpty ? value.gender : 'Unknown',
      'age': value.age ?? 'Unknown',
      'healthcareNumber': value.healthcareNumber.isNotEmpty ? value.healthcareNumber : 'Unknown',
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

    final docRef = await _firestore.collection('patients').add({
      ..._patientFields(value),
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
    final fields = _patientFields(value);
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

final patientUploadServiceProvider = Provider<PatientUploadService>((ref) {
  return PatientUploadService(FirebaseFirestore.instance);
});
