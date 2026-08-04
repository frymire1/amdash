import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Mirrors `apps/physician/src/app/services/patient.service.ts`:
/// re-subscribes whenever the signed-in user's own org changes, listing
/// only this org's *active* patients, newest first. Completed/archived
/// patients never show up here — there's no completed-patients view in
/// this app.
final physicianPatientsProvider = StreamProvider<List<Patient>>((ref) async* {
  final profileAsync = ref.watch(userProfileProvider);

  // userProfileProvider mid-rebuild (e.g. right after a fresh sign-in
  // replaces a signed-out session) reports `hasValue: true` while
  // `isLoading: true` — Riverpod carries the *previous* value forward
  // during the transition (here, a stale `null` profile from before
  // sign-in), so `hasValue` alone doesn't mean the value is current.
  // `isLoading` is the reliable signal: don't trust anything while a
  // recomputation is in flight, regardless of whether it's carrying
  // forward stale data. Confirmed via a real run: without this, a fresh
  // login briefly saw a stale `orgId: null` and reported "zero patients"
  // before the real profile settled.
  if (profileAsync.isLoading) return;

  final organizationId = profileAsync.valueOrNull?.organizationId;
  if (organizationId == null) {
    yield const [];
    return;
  }

  final query = FirebaseFirestore.instance
      .collection('patients')
      .where('organizationId', isEqualTo: organizationId)
      .where('status', isEqualTo: 'active')
      .orderBy('submittedAt', descending: true);

  // Only trust a server-confirmed snapshot — see userProfileProvider's own
  // doc listener for why `includeMetadataChanges: true` is required for a
  // `!isFromCache` filter to ever unblock.
  yield* query.snapshots(includeMetadataChanges: true).where((snapshot) => !snapshot.metadata.isFromCache).map(
    (snapshot) => snapshot.docs.map((doc) => Patient.fromFirestore(doc.id, doc.data())).toList(),
  );
});
