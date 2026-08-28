import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:ems/classes/uploaded_patient.dart';
import 'package:ems/services/patient_session_service.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// uploadedPatientsProvider is a plain `Provider<AsyncValue<T>>` wrapping a
// private StreamProvider this test file can't reach directly (Dart privacy
// is per-file) — so unlike a StreamProvider/FutureProvider, it has no
// `.future` to await. `container.listen(..., fireImmediately: true)`
// resolves as soon as a non-loading value is delivered, whether that's
// synchronously (already settled) or after the wrapped stream's first
// microtask-delivered snapshot — same settling-race concern as every other
// provider test in this repo, just without a `.future` shortcut available.
Future<AsyncValue<List<UploadedPatient>>> _settled(ProviderContainer container) {
  final completer = Completer<AsyncValue<List<UploadedPatient>>>();
  late final ProviderSubscription<AsyncValue<List<UploadedPatient>>> sub;
  sub = container.listen(uploadedPatientsProvider, (previous, next) {
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

  // See amdash_core/test/hospitals/hospital_service_test.dart's own comment
  // for why userProfileProvider must be fully settled before
  // uploadedPatientsProvider (which watches it) is ever read.
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

  group('uploadedPatientsProvider', () {
    test('yields an empty list while the profile has no organizationId yet', () async {
      final container = await containerFor(null);
      addTearDown(container.dispose);

      final patients = (await _settled(container)).value!;
      expect(patients, isEmpty);
    });

    test("lists only this org's active patients, newest first", () async {
      const profile = UserProfile(role: [UserRole.ems], organizationId: 'org-1');
      final container = await containerFor(profile);
      addTearDown(container.dispose);

      final patients = (await _settled(container)).value!;
      expect(patients.map((u) => u.patient.name.plaintext), ['Newer Patient', 'Older Patient']);
    });
  });

  group('findUploadedPatient', () {
    test('finds the patient with a matching id', () {
      final patients = [
        UploadedPatient(id: 'p1', patient: Patient.fromFirestore('p1', const {})),
        UploadedPatient(id: 'p2', patient: Patient.fromFirestore('p2', const {})),
      ];
      expect(findUploadedPatient(patients, 'p2')?.id, 'p2');
    });

    test('returns null when nothing matches', () {
      final patients = [UploadedPatient(id: 'p1', patient: Patient.fromFirestore('p1', const {}))];
      expect(findUploadedPatient(patients, 'nope'), isNull);
    });
  });
}
