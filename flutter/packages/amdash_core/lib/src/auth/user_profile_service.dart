import 'package:cloud_firestore/cloud_firestore.dart';
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
  final user = authState.valueOrNull;

  if (user == null) {
    yield null;
    return;
  }

  yield* FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .snapshots()
      .map((snapshot) {
        final data = snapshot.data();
        return data == null ? null : UserProfile.fromFirestore(data);
      });
});
