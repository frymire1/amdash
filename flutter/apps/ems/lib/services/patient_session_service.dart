import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/uploaded_patient.dart';

/// Mirrors `apps/ems/src/app/services/patient-session.service.ts`:
/// re-subscribes whenever the signed-in user's own org changes, listing
/// only this org's *active* patients, newest first.
final uploadedPatientsProvider = StreamProvider<List<UploadedPatient>>((ref) async* {
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

UploadedPatient? findUploadedPatient(List<UploadedPatient> patients, String id) {
  for (final uploaded in patients) {
    if (uploaded.id == id) return uploaded;
  }
  return null;
}
