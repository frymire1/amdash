import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physician/services/patient_service.dart';

// See ems/test/services/patient_session_service_test.dart's identical
// helper (this provider mirrors that one exactly) for why a manual
// `container.listen(..., fireImmediately: true)` settle is needed instead
// of a `.future` shortcut.
Future<AsyncValue<List<Patient>>> _settled(ProviderContainer container) {
  final completer = Completer<AsyncValue<List<Patient>>>();
  late final ProviderSubscription<AsyncValue<List<Patient>>> sub;
  sub = container.listen(physicianPatientsProvider, (previous, next) {
    if (!next.isLoading && !completer.isCompleted) {
      completer.complete(next);
      sub.close();
    }
  }, fireImmediately: true);
  return completer.future;
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() async {
    firestore = FakeFirebaseFirestore();
    await firestore.collection('patients').add({
      'organizationId': 'org-1',
      'status': 'active',
      'name': 'Older Patient',
      'submittedAt': DateTime(2024, 1, 1),
    });
    await firestore.collection('patients').add({
      'organizationId': 'org-1',
      'status': 'active',
      'name': 'Newer Patient',
      'submittedAt': DateTime(2024, 1, 2),
    });
    await firestore.collection('patients').add({
      'organizationId': 'org-1',
      'status': 'completed',
      'name': 'Completed Patient',
      'submittedAt': DateTime(2024, 1, 3),
    });
    await firestore.collection('patients').add({
      'organizationId': 'org-2',
      'status': 'active',
      'name': 'Other Org Patient',
      'submittedAt': DateTime(2024, 1, 4),
    });
  });

  Future<ProviderContainer> containerFor(UserProfile? profile) async {
    final container = ProviderContainer(
      overrides: [
        firestoreProvider.overrideWithValue(firestore),
        userProfileProvider.overrideWith((ref) => Stream.value(profile)),
      ],
    );
    await container.read(userProfileProvider.future);
    return container;
  }

  group('physicianPatientsProvider', () {
    test('yields an empty list while the profile has no organizationId yet', () async {
      final container = await containerFor(null);
      addTearDown(container.dispose);

      final patients = (await _settled(container)).value!;
      expect(patients, isEmpty);
    });

    test("lists only this org's active patients, newest first — completed/other-org excluded", () async {
      const profile = UserProfile(role: [UserRole.physician], organizationId: 'org-1');
      final container = await containerFor(profile);
      addTearDown(container.dispose);

      final patients = (await _settled(container)).value!;
      expect(patients.map((p) => p.name.plaintext), ['Newer Patient', 'Older Patient']);
    });
  });
}
