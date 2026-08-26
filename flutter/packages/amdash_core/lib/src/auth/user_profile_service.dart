import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  ) {
    return _doc(uid).set({
      'newPatientAlertsExpiresAt': expiresAt,
      'fcmTokens': FieldValue.arrayUnion([fcmToken]),
    }, SetOptions(merge: true));
  }

  Future<void> disableNewPatientAlerts(String uid) {
    return _doc(
      uid,
    ).set({'newPatientAlertsExpiresAt': FieldValue.delete()}, SetOptions(merge: true));
  }
}

final userProfileServiceProvider = Provider<UserProfileService>((ref) {
  return UserProfileService(FirebaseFirestore.instance);
});

/// Mirrors `UserProfileService.profile`/`loading` signals: re-subscribes
/// whenever the signed-in user changes (including signing out, which
/// yields `null`).
final userProfileProvider = StreamProvider<UserProfile?>((ref) async* {
  final authState = ref.watch(authStateProvider);
  // TODO(debug): temporary — see authStateProvider's own TODO(debug).
  debugPrint(
    '[DIAG] userProfileProvider: build() entered, authState.isLoading=${authState.isLoading} '
    'hasValue=${authState.hasValue} uid=${authState.valueOrNull?.uid} at ${DateTime.now()}',
  );

  // While a recomputation is in flight, authState.hasValue can still be
  // true — Riverpod carries the *previous* value forward during a
  // rebuild — so `isLoading` alone is the reliable "don't trust this yet"
  // signal (see physicianPatientsProvider's identical check for the real
  // failure this guards against: a stale value read as if it were
  // settled).
  if (authState.isLoading) {
    debugPrint('[DIAG] userProfileProvider: returning early, authState still loading');
    return;
  }

  final user = authState.valueOrNull;

  if (user == null) {
    debugPrint('[DIAG] userProfileProvider: no user, yielding null');
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
  debugPrint('[DIAG] userProfileProvider: subscribing to users/${user.uid} snapshots at ${DateTime.now()}');
  yield* FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .snapshots(includeMetadataChanges: true)
      .map((snapshot) {
        debugPrint(
          '[DIAG] userProfileProvider: snapshot exists=${snapshot.exists} '
          'isFromCache=${snapshot.metadata.isFromCache} '
          'hasPendingWrites=${snapshot.metadata.hasPendingWrites} at ${DateTime.now()}',
        );
        return snapshot;
      })
      .where((snapshot) => !snapshot.metadata.isFromCache)
      .map((snapshot) {
        final data = snapshot.data();
        return data == null ? null : UserProfile.fromFirestore(data);
      });
});
