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
///
/// Reads `.valueOrNull` rather than `AsyncValue.whenData(...)` —
/// `_rawUploadedPatientsProvider` rebuilding (its own `userProfileProvider`
/// dependency re-emitting, or just its live Firestore query listener
/// resyncing after the app returns from the background, which redelivers
/// the current snapshot even when nothing actually changed) leaves it
/// `isLoading` but still `hasValue` — Riverpod carries the previous value
/// forward across a dependency-triggered reload. `whenData`'s own `loading`
/// branch ignored that and always returned a bare, valueless
/// `AsyncLoading()`, which flashed every screen watching this provider back
/// to a loading spinner on every app resume, even though the list hadn't
/// changed. Reading `.valueOrNull` instead keeps showing the last-known
/// list (refreshing silently underneath) until real new data lands, and
/// only falls through to a loading/error state when there's truly nothing
/// to show yet.
final uploadedPatientsProvider = Provider<AsyncValue<List<UploadedPatient>>>((ref) {
  final rawAsync = ref.watch(_rawUploadedPatientsProvider);
  final uploaded = rawAsync.valueOrNull;
  if (uploaded != null) {
    final resolved = withCachedDecryptedFields(ref, [for (final u in uploaded) u.patient]);
    return AsyncData([
      for (var i = 0; i < uploaded.length; i++) UploadedPatient(id: uploaded[i].id, patient: resolved[i]),
    ]);
  }
  if (rawAsync.hasError) return AsyncError(rawAsync.error!, rawAsync.stackTrace!);
  return const AsyncLoading();
});

UploadedPatient? findUploadedPatient(List<UploadedPatient> patients, String id) {
  for (final uploaded in patients) {
    if (uploaded.id == id) return uploaded;
  }
  return null;
}
