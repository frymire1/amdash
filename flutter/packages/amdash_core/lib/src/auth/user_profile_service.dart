import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../firebase/firebase_providers.dart';
import '../models/user_profile.dart';
import 'auth_service.dart';

/// Mirrors `libs/auth/src/lib/services/user-profile.service.ts`: loads and
/// writes the signed-in user's own `users/{uid}` doc. Every mutator here
/// re-reads after writing (via `userProfileProvider`'s own stream
/// re-emitting) rather than optimistically merging locally — same reason
/// as the Angular version: a locally-spliced object could still be
/// clobbering a stale pre-role snapshot if this is the very first read.
class UserProfileService {
  UserProfileService(this._firestore);

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, Object?>> _doc(String uid) =>
      _firestore.collection('users').doc(uid);

  Future<void> initializeProfile(String uid, String email) {
    return _doc(uid).set({'email': email}, SetOptions(merge: true));
  }

  Future<void> saveProfile(String uid, String firstName, String lastName) {
    return _doc(
      uid,
    ).set({'firstName': firstName, 'lastName': lastName}, SetOptions(merge: true));
  }

  Future<void> saveWorkLocation(String uid, String workLocation) {
    return _doc(
      uid,
    ).set({'workLocation': workLocation}, SetOptions(merge: true));
  }

  Future<void> enableNewPatientAlerts(
    String uid,
    Timestamp expiresAt,
    String fcmToken,
    List<int> etaAlertThresholdsMinutes,
  ) {
    return _doc(uid).set({
      'newPatientAlertsExpiresAt': expiresAt,
      'fcmTokens': FieldValue.arrayUnion([fcmToken]),
      'etaAlertThresholdsMinutes': etaAlertThresholdsMinutes,
    }, SetOptions(merge: true));
  }

  Future<void> disableNewPatientAlerts(String uid) {
    return _doc(
      uid,
    ).set({'newPatientAlertsExpiresAt': FieldValue.delete()}, SetOptions(merge: true));
  }

  /// Registers one more FCM token for push delivery to this user, without
  /// touching `newPatientAlertsExpiresAt`/`etaAlertThresholdsMinutes` —
  /// those are physician-specific proximity-alert preferences (see
  /// [enableNewPatientAlerts] above). This is the plain "add me a token"
  /// write EMS's own connectivity-loss alerts need instead — registered
  /// automatically at sign-in, not an opt-in preference with an expiry
  /// (see `ems`'s `ems_alert_service.dart`).
  Future<void> registerFcmToken(String uid, String fcmToken) {
    return _doc(uid).set({'fcmTokens': FieldValue.arrayUnion([fcmToken])}, SetOptions(merge: true));
  }
}

final userProfileServiceProvider = Provider<UserProfileService>((ref) {
  return UserProfileService(ref.watch(firestoreProvider));
});

/// Mirrors `UserProfileService.profile`/`loading` signals: re-subscribes
/// whenever the signed-in user changes (including signing out, which
/// yields `null`).
final userProfileProvider = StreamProvider<UserProfile?>((ref) async* {
  final authState = ref.watch(authStateProvider);

  // While a recomputation is in flight, authState.hasValue can still be
  // true — Riverpod carries the *previous* value forward during a
  // rebuild — so `isLoading` alone is the reliable "don't trust this yet"
  // signal (see physicianPatientsProvider's identical check for the real
  // failure this guards against: a stale value read as if it were
  // settled).
  if (authState.isLoading) return;

  final user = authState.valueOrNull;

  if (user == null) {
    yield null;
    return;
  }

  // A freshly (re)attached listener — e.g. after an auth token refresh
  // recreates this provider (see RouterRefreshNotifier/AppRouteGuard,
  // which has to work around the same thing) — emits its first snapshot
  // from the local cache before the server-confirmed one, and that first
  // cached read can transiently miss a since-added field (confirmed via a
  // real run: organizationId read as null from the cached snapshot, then
  // correctly populated moments later from the server-confirmed one).
  // Only trust a server-confirmed snapshot. Requires
  // `includeMetadataChanges: true`: with the default `false`, Firestore
  // only fires a new event when the *data* changes, and a fresh sign-in's
  // cached copy is often already identical to what the server goes on to
  // confirm — no data change means no second event ever fires, and a
  // plain `.where((s) => !s.metadata.isFromCache)` then blocks forever
  // (confirmed the hard way: this exact bug, on this exact line, minus
  // `includeMetadataChanges: true`, broke fresh sign-in outright).
  yield* ref
      .watch(firestoreProvider)
      .collection('users')
      .doc(user.uid)
      .snapshots(includeMetadataChanges: true)
      .where((snapshot) => !snapshot.metadata.isFromCache)
      .map((snapshot) {
        final data = snapshot.data();
        return data == null ? null : UserProfile.fromFirestore(data);
      });
});
