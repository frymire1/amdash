import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/uploaded_patient.dart';

/// Mirrors `apps/ems/src/app/services/patient-session.service.ts`:
/// re-subscribes whenever the signed-in user's own org changes, listing
/// only this org's *active* patients, newest first. Private/raw —
/// [uploadedPatientsProvider] below is the one widgets should actually
/// watch; it wraps this with decrypted-field splicing.
final _rawUploadedPatientsProvider = StreamProvider<List<UploadedPatient>>((ref) async* {
  final profileState = ref.watch(userProfileProvider);

  // userProfileProvider mid-rebuild (e.g. right after a fresh sign-in
  // replaces a signed-out session) reports `hasValue: true` while
  // `isLoading: true` — Riverpod carries the *previous* value forward
  // during the transition — so `hasValue`/`valueOrNull` alone doesn't mean
  // the value is current. `isLoading` is the reliable signal: don't trust
  // anything while a recomputation is in flight. See
  // physician/lib/services/patient_service.dart's identical guard for the
  // real failure this avoids: without it, this briefly judged "no org yet"
  // and yielded an empty list, then rebuilt from scratch once the real
  // profile settled — a visible flash on every fresh load.
  if (profileState.isLoading) return;

  final profile = profileState.valueOrNull;
  if (profile?.organizationId == null) {
    yield const [];
    return;
  }

  final query = ref
      .watch(firestoreProvider)
      .collection('patients')
      .where('organizationId', isEqualTo: profile!.organizationId)
      .where('status', isEqualTo: 'active')
      .orderBy('submittedAt', descending: true);

  // Only trust a server-confirmed snapshot — see userProfileProvider's own
  // doc listener for why `includeMetadataChanges: true` is required for a
  // `!isFromCache` filter to ever unblock. Without this, the very first
  // snapshot Firestore's offline persistence serves up front — whatever
  // this device last had cached, from a previous session, possibly with
  // patients that have since been completed/removed — rendered immediately
  // as if it were current.
  yield* query.snapshots(includeMetadataChanges: true).where((snapshot) => !snapshot.metadata.isFromCache).map(
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
