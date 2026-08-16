import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/uploaded_patient.dart';

/// Mirrors `apps/ems/src/app/services/patient-session.service.ts`:
/// re-subscribes whenever the signed-in user's own org changes, listing
/// only this org's *active* patients, newest first. Private/raw —
/// [uploadedPatientsProvider] below is the one widgets should actually
/// watch; it wraps this with decrypted-field splicing.
final _rawUploadedPatientsProvider = StreamProvider<List<UploadedPatient>>((ref) async* {
  final profileState = ref.watch(userProfileProvider);
  final profile = profileState.valueOrNull;

  if (profile?.organizationId == null) {
    yield const [];
    return;
  }

  final query = FirebaseFirestore.instance
      .collection('patients')
      .where('organizationId', isEqualTo: profile!.organizationId)
      .where('status', isEqualTo: 'active')
      .orderBy('submittedAt', descending: true);

  yield* query.snapshots().map(
    (snapshot) => snapshot.docs
        .map((doc) => UploadedPatient(id: doc.id, patient: Patient.fromFirestore(doc.id, doc.data())))
        .toList(),
  );
});

/// The provider every widget actually watches — see
/// physician/lib/services/patient_service.dart's identical wrapper for the
/// full rationale (kept in sync with that one). `UploadedPatient` wraps a
/// `Patient`, so splicing happens through its `.patient` field.
final uploadedPatientsProvider = Provider<AsyncValue<List<UploadedPatient>>>((ref) {
  final rawAsync = ref.watch(_rawUploadedPatientsProvider);
  return rawAsync.whenData((uploaded) {
    final resolved = withCachedDecryptedFields(ref, [for (final u in uploaded) u.patient]);
    return [
      for (var i = 0; i < uploaded.length; i++) UploadedPatient(id: uploaded[i].id, patient: resolved[i]),
    ];
  });
});

UploadedPatient? findUploadedPatient(List<UploadedPatient> patients, String id) {
  for (final uploaded in patients) {
    if (uploaded.id == id) return uploaded;
  }
  return null;
}
