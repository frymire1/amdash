import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Mirrors `apps/physician/src/app/services/patient.service.ts`:
/// re-subscribes whenever the signed-in user's own org changes, listing
/// only this org's *active* patients, newest first. Completed/archived
/// patients never show up here — there's no completed-patients view in
/// this app.
final physicianPatientsProvider = StreamProvider<List<Patient>>((ref) async* {
  final profile = ref.watch(userProfileProvider).valueOrNull;

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
    (snapshot) => snapshot.docs.map((doc) => Patient.fromFirestore(doc.id, doc.data())).toList(),
  );
});
