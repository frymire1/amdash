import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/user_profile_service.dart';
import '../models/hospital.dart';
import '../models/user_profile.dart';

/// Mirrors `libs/auth/src/lib/hospitals.ts`: a super-admin sees every
/// hospital across every organization (rules-legal cross-org visibility by
/// design); everyone else is scoped to their own `organizationId`. Empty
/// while the profile hasn't loaded yet, or (for non-super-admins) has no
/// org yet.
final hospitalsProvider = StreamProvider<List<Hospital>>((ref) async* {
  final profileState = ref.watch(userProfileProvider);
  final profile = profileState.valueOrNull;

  if (profile == null) {
    yield const [];
    return;
  }

  final firestore = FirebaseFirestore.instance;
  Query<Map<String, Object?>> query = firestore
      .collection('hospitals')
      .orderBy('name');

  if (!profile.hasRole(UserRole.superAdmin)) {
    if (profile.organizationId == null) {
      yield const [];
      return;
    }
    query = firestore
        .collection('hospitals')
        .where('organizationId', isEqualTo: profile.organizationId)
        .orderBy('name');
  }

  yield* query.snapshots().map(
    (snapshot) => snapshot.docs
        .map((doc) => Hospital.fromFirestore(doc.id, doc.data()))
        .toList(),
  );
});

final hospitalNamesProvider = Provider<List<String>>((ref) {
  final hospitals = ref.watch(hospitalsProvider).valueOrNull ?? const [];
  return hospitals.map((hospital) => hospital.name).toList();
});
