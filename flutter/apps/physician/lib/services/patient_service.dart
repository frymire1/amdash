import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Mirrors `apps/physician/src/app/services/patient.service.ts`:
/// re-subscribes whenever the signed-in user's own org changes, listing
/// only this org's *active* patients, newest first. Completed/archived
/// patients never show up here — there's no completed-patients view in
/// this app. Private/raw — [physicianPatientsProvider] below is the one
/// widgets should actually watch; it wraps this with decrypted-field
/// splicing.
final _rawPhysicianPatientsProvider = StreamProvider<List<Patient>>((ref) async* {
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

  final query = ref
      .watch(firestoreProvider)
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

/// The provider every widget actually watches. Splices in whatever's
/// already decrypted in `patientFieldCacheProvider` (amdash_core) and
/// kicks a background pull for anything encrypted and still missing —
/// the list renders immediately with "Decrypting…" placeholders rather
/// than waiting on that pull. Riverpod's `Provider<AsyncValue<T>>` here
/// resolves to the exact same `AsyncValue<List<Patient>>` shape a
/// `StreamProvider<List<Patient>>` would, so this is a drop-in swap —
/// nothing downstream needed to change how it reads this provider.
final physicianPatientsProvider = Provider<AsyncValue<List<Patient>>>((ref) {
  final rawAsync = ref.watch(_rawPhysicianPatientsProvider);
  return rawAsync.whenData((patients) => withCachedDecryptedFields(ref, patients));
});
