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

    // Regression test for a real bug — see
    // ems/test/services/patient_session_service_test.dart's identical case
    // for the full rationale (kept in sync with that one): minimizing then
    // reopening the app flashed the screen back to a bare loading spinner
    // even when nothing had changed, because `AsyncValue.whenData(...)`
    // discarded the raw provider's previous value on every
    // dependency-triggered reload (e.g. the profile listener resyncing
    // after backgrounding), not just on a genuine first load.
    test('reloading (e.g. the profile stream re-emitting) never regresses to a valueless loading state', () async {
      const profile = UserProfile(role: [UserRole.physician], organizationId: 'org-1');
      final profileController = StreamController<UserProfile?>();
      addTearDown(profileController.close);
      final container = ProviderContainer(
        overrides: [
          firestoreProvider.overrideWithValue(firestore),
          userProfileProvider.overrideWith((ref) => profileController.stream),
        ],
      );
      addTearDown(container.dispose);

      final states = <AsyncValue<List<Patient>>>[];
      Completer<void>? settled;
      container.listen(physicianPatientsProvider, (previous, next) {
        states.add(next);
        if (!next.isLoading) settled?.complete();
      }, fireImmediately: true);

      settled = Completer<void>();
      profileController.add(profile);
      await settled.future;
      expect(states.last.value?.map((p) => p.name.plaintext), ['Newer Patient', 'Older Patient']);

      // Only states from here on are relevant to the regression — the
      // provider's very first-ever state (before anything has loaded at
      // all) is a legitimate, real `AsyncLoading()`, not the bug.
      states.clear();

      // Re-emits an equivalent (not necessarily identical-by-reference)
      // profile — simulating the live listener resyncing after resume and
      // redelivering its current value even though nothing actually
      // changed, which is exactly what rebuilds the raw provider here.
      settled = Completer<void>();
      profileController.add(profile);
      await settled.future;

      for (final state in states) {
        expect(state.hasValue, isTrue, reason: 'regressed to a valueless loading state: $state');
      }
      expect(states.last.value?.map((p) => p.name.plaintext), ['Newer Patient', 'Older Patient']);
    });
  });
}
