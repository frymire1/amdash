// cloud_firestore marks Query/DocumentReference/DocumentSnapshot @sealed
// (a package:meta lint annotation, not the real Dart `sealed` keyword —
// confirmed by reading cloud_firestore's own source: it's a plain
// `abstract class`, so this still works correctly with mocktail at
// runtime) purely to reserve the right to add members without breaking
// external implementers — mocktail's `Mock implements` doesn't add
// members, so the lint's own concern doesn't actually apply here.
// Confirmed via fake_cloud_firestore's own source (mock_snapshot_metadata.dart)
// that its `hasPendingWrites` is hardcoded `false`, never configurable —
// there is no fake that can produce the "pending write" / "never
// confirms" streams the completeTransportConfirmed group below needs, so
// mocking the real SDK types directly is the only way to exercise its
// retry/give-up branches at all.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:ems/services/patient_upload_service.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

class _MockHttpsCallable extends Mock implements HttpsCallable {}

class _MockHttpsCallableResult<T> extends Mock implements HttpsCallableResult<T> {}

// Full mocktail Firestore chain, not FakeFirebaseFirestore — only used for
// completeTransportConfirmed's own group below, since exercising its retry
// (attempt fails to confirm, tries again) and give-up (every attempt fails
// to confirm) branches needs precise control over what _waitForStatus's
// `.snapshots(includeMetadataChanges: true)` stream emits on each of
// several separate calls, which a real in-memory fake (always confirms a
// write near-instantly) can't produce. An *empty* stream (no events at
// all) makes the `await for` loop complete with zero iterations — no real
// wait, and no TimeoutException either, since the source stream ends on
// its own rather than timing out — which is exactly "this attempt's
// confirming read never observed a matching snapshot", without needing to
// wait out the real 6-second Duration hardcoded in _waitForStatus.
class _MockFirestore extends Mock implements FirebaseFirestore {}

// See this file's own top-of-file ignore_for_file comment for why
// implementing these 3 sealed SDK types directly is the right call here.
class _MockCollectionRef extends Mock implements CollectionReference<Map<String, dynamic>> {}

class _MockDocRef extends Mock implements DocumentReference<Map<String, dynamic>> {}

class _MockSnapshot extends Mock implements DocumentSnapshot<Map<String, dynamic>> {}

class _MockMetadata extends Mock implements SnapshotMetadata {}

PatientFormValues _formValues({
  String name = '',
  String healthcareNumber = '',
  String gender = '',
  num? age,
  String destination = '',
  String ivSize = '',
  String ivPlacement = '',
  String treatment = '',
  String notes = '',
}) {
  return PatientFormValues(
    name: name,
    gender: gender,
    age: age,
    healthcareNumber: healthcareNumber,
    destination: destination,
    heartRate: null,
    bloodPressure: '',
    oxygen: null,
    temperature: null,
    respiratoryRate: null,
    gcs: null,
    ivSize: ivSize,
    ivPlacement: ivPlacement,
    treatment: treatment,
    notes: notes,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(<String, Object?>{});
  });

  group('resolveBlankField', () {
    test('a non-empty value passes through unchanged', () {
      expect(resolveBlankField('Jordan Smith'), 'Jordan Smith');
    });

    test('an empty value resolves to the Unknown sentinel', () {
      expect(resolveBlankField(''), 'Unknown');
    });
  });

  group('PatientSaveException', () {
    test('toString() includes the underlying cause', () {
      final exception = PatientSaveException(Exception('network error'));
      expect(exception.toString(), "Failed to save this patient: Exception: network error");
    });
  });

  group('with FakeFirebaseFirestore', () {
    late FakeFirebaseFirestore firestore;
    late _MockFirebaseFunctions functions;
    late _MockHttpsCallable callable;
    late MockFirebaseAuth auth;
    late PatientUploadService service;

    setUp(() {
      firestore = FakeFirebaseFirestore();
      functions = _MockFirebaseFunctions();
      callable = _MockHttpsCallable();
      auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'user-1'));
      service = PatientUploadService(firestore, functions, auth);
      PatientUploadService.debugCallCount = 0;
      PatientUploadService.debugCallStacks.clear();
      PatientUploadService.debugLastUploadedPatientId = null;
    });

    group('uploadPatient', () {
      test('resolves blank name/healthcareNumber to Unknown, includes lat/lng only when both given', () async {
        when(() => functions.httpsCallable('uploadPatientDocument')).thenReturn(callable);
        final result = _MockHttpsCallableResult<Map<Object?, Object?>>();
        when(() => result.data).thenReturn({'id': 'patient-1', 'name': 'Unknown', 'healthcareNumber': 'Unknown'});
        when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => result);

        final saved = await service.uploadPatient(_formValues(), latitude: 45.4, longitude: -75.7);

        expect(saved.id, 'patient-1');
        expect(saved.nameFingerprint, isNull);
        expect(saved.healthcareNumberFingerprint, isNull);
        verify(
          () => callable.call<Map<Object?, Object?>>(
            any(
              that: predicate<Map<Object?, Object?>>(
                (m) =>
                    m['name'] == 'Unknown' &&
                    m['healthcareNumber'] == 'Unknown' &&
                    m['latitude'] == 45.4 &&
                    m['longitude'] == -75.7,
              ),
            ),
          ),
        ).called(1);
        expect(PatientUploadService.debugCallCount, 1);
        expect(PatientUploadService.debugCallStacks, hasLength(1));
        expect(PatientUploadService.debugLastUploadedPatientId, 'patient-1');
      });

      test('omits latitude/longitude entirely when not provided', () async {
        when(() => functions.httpsCallable('uploadPatientDocument')).thenReturn(callable);
        final result = _MockHttpsCallableResult<Map<Object?, Object?>>();
        when(() => result.data).thenReturn({'id': 'patient-1'});
        when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => result);

        await service.uploadPatient(_formValues(name: 'Jordan Smith'));

        verify(
          () => callable.call<Map<Object?, Object?>>(
            any(
              that: predicate<Map<Object?, Object?>>(
                (m) => !m.containsKey('latitude') && !m.containsKey('longitude') && m['name'] == 'Jordan Smith',
              ),
            ),
          ),
        ).called(1);
      });

      test('captures encrypted-field fingerprints from the response', () async {
        when(() => functions.httpsCallable('uploadPatientDocument')).thenReturn(callable);
        final result = _MockHttpsCallableResult<Map<Object?, Object?>>();
        when(() => result.data).thenReturn({
          'id': 'patient-1',
          'name': {'ciphertext': 'name-fp'},
          'healthcareNumber': {'ciphertext': 'hcn-fp'},
        });
        when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => result);

        final saved = await service.uploadPatient(_formValues());

        expect(saved.nameFingerprint, 'name-fp');
        expect(saved.healthcareNumberFingerprint, 'hcn-fp');
      });

      test('a callable failure is wrapped in PatientSaveException', () async {
        when(() => functions.httpsCallable('uploadPatientDocument')).thenReturn(callable);
        when(() => callable.call<Map<Object?, Object?>>(any())).thenThrow(
          FirebaseFunctionsException(code: 'internal', message: 'boom'),
        );

        await expectLater(service.uploadPatient(_formValues()), throwsA(isA<PatientSaveException>()));
      });
    });

    group('updatePatient', () {
      test('encrypts name/healthcareNumber via encryptPatientFields, then writes the merged fields', () async {
        when(() => functions.httpsCallable('encryptPatientFields')).thenReturn(callable);
        final result = _MockHttpsCallableResult<Map<Object?, Object?>>();
        when(() => result.data).thenReturn({
          'name': {'ciphertext': 'name-fp'},
          'healthcareNumber': {'ciphertext': 'hcn-fp'},
        });
        when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => result);

        await firestore.collection('patients').doc('patient-1').set({'status': 'active'});

        final saved = await service.updatePatient(
          'patient-1',
          _formValues(name: 'Jordan Smith', ivSize: '18G'),
        );

        expect(saved.nameFingerprint, 'name-fp');
        expect(saved.healthcareNumberFingerprint, 'hcn-fp');

        final doc = await firestore.collection('patients').doc('patient-1').get();
        final data = doc.data()!;
        expect((data['name'] as Map)['ciphertext'], 'name-fp');
        expect(data['ivSize'], '18G');
        expect(data['updatedBy'], 'user-1');
      });

      test('deletes optional top-level fields the form left blank rather than leaving stale values', () async {
        when(() => functions.httpsCallable('encryptPatientFields')).thenReturn(callable);
        final result = _MockHttpsCallableResult<Map<Object?, Object?>>();
        when(() => result.data).thenReturn(const <String, Object?>{});
        when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => result);

        await firestore.collection('patients').doc('patient-1').set({
          'status': 'active',
          'ivSize': '18G',
          'ivPlacement': 'Left AC',
          'treatment': 'Fluids',
        });

        // Every optional field left blank on this update.
        await service.updatePatient('patient-1', _formValues());

        final doc = await firestore.collection('patients').doc('patient-1').get();
        final data = doc.data()!;
        expect(data.containsKey('ivSize'), false);
        expect(data.containsKey('ivPlacement'), false);
        expect(data.containsKey('treatment'), false);
      });

      test('an encryptPatientFields failure is wrapped in PatientSaveException and never falls back to plaintext', () async {
        when(() => functions.httpsCallable('encryptPatientFields')).thenReturn(callable);
        when(() => callable.call<Map<Object?, Object?>>(any())).thenThrow(
          FirebaseFunctionsException(code: 'internal', message: 'boom'),
        );

        await firestore.collection('patients').doc('patient-1').set({'status': 'active'});

        await expectLater(
          service.updatePatient('patient-1', _formValues(name: 'Jordan Smith')),
          throwsA(isA<PatientSaveException>()),
        );

        // Confirms nothing was written at all — not even a plaintext fallback.
        final doc = await firestore.collection('patients').doc('patient-1').get();
        expect(doc.data()!.containsKey('name'), false);
      });
    });

    group('deletePatient', () {
      test('calls deletePatientRecord with patientId', () async {
        when(() => functions.httpsCallable('deletePatientRecord')).thenReturn(callable);
        when(() => callable.call<void>(any())).thenAnswer((_) async => _MockHttpsCallableResult<void>());

        await service.deletePatient('patient-1');

        verify(() => callable.call<void>({'patientId': 'patient-1'})).called(1);
      });
    });

    group('completeTransport', () {
      test('writes status=completed and stamps updatedBy from the signed-in user', () async {
        await firestore.collection('patients').doc('patient-1').set({'status': 'active'});

        await service.completeTransport('patient-1');

        final doc = await firestore.collection('patients').doc('patient-1').get();
        final data = doc.data()!;
        expect(data['status'], 'completed');
        expect(data['updatedBy'], 'user-1');
        expect(data['completedAt'], isNotNull);
      });
    });
  });

  group('completeTransportConfirmed', () {
    late _MockFirestore firestore;
    late _MockCollectionRef collectionRef;
    late _MockDocRef docRef;
    late MockFirebaseAuth auth;
    late PatientUploadService service;

    setUp(() {
      firestore = _MockFirestore();
      collectionRef = _MockCollectionRef();
      docRef = _MockDocRef();
      auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'user-1'));
      service = PatientUploadService(firestore, _MockFirebaseFunctions(), auth);

      when(() => firestore.collection('patients')).thenReturn(collectionRef);
      when(() => collectionRef.doc('patient-1')).thenReturn(docRef);
      when(() => docRef.update(any())).thenAnswer((_) async {});
    });

    _MockSnapshot matchingSnapshot() {
      final metadata = _MockMetadata();
      when(() => metadata.hasPendingWrites).thenReturn(false);
      final snapshot = _MockSnapshot();
      when(() => snapshot.metadata).thenReturn(metadata);
      when(() => snapshot.exists).thenReturn(true);
      when(() => snapshot.data()).thenReturn({'status': 'completed'});
      return snapshot;
    }

    test('confirms and returns on the very first attempt', () async {
      when(
        () => docRef.snapshots(includeMetadataChanges: true),
      ).thenAnswer((_) => Stream.value(matchingSnapshot()));

      await service.completeTransportConfirmed('patient-1');

      verify(() => docRef.update(any())).called(1);
    });

    test('retries once when the first confirming read observes nothing, then succeeds on the second', () async {
      var call = 0;
      when(() => docRef.snapshots(includeMetadataChanges: true)).thenAnswer((_) {
        call++;
        // First attempt's confirming read never sees a matching snapshot
        // (an empty stream completes with zero events, distinct from a
        // real timeout — see this file's own header comment); the second
        // attempt's does.
        return call == 1 ? const Stream<DocumentSnapshot<Map<String, dynamic>>>.empty() : Stream.value(matchingSnapshot());
      });

      await service.completeTransportConfirmed('patient-1', maxAttempts: 3);

      verify(() => docRef.update(any())).called(2);
    });

    test('throws StateError once every attempt fails to confirm', () async {
      when(
        () => docRef.snapshots(includeMetadataChanges: true),
      ).thenAnswer((_) => const Stream<DocumentSnapshot<Map<String, dynamic>>>.empty());

      await expectLater(
        service.completeTransportConfirmed('patient-1', maxAttempts: 3),
        throwsA(isA<StateError>()),
      );
      verify(() => docRef.update(any())).called(3);
    });

    // Real ~6s wait (see _waitForStatus's own hardcoded Duration) — the
    // empty-stream trick used everywhere else in this group deliberately
    // completes without emitting rather than hanging, so it can't
    // exercise the genuine on TimeoutException branch; a stream that
    // truly never emits or closes is the only way to force that for
    // real. Kept to exactly this one case (maxAttempts: 1) so it only
    // pays the delay once, matching this repo's existing precedent (see
    // fhir_export_service_test.dart's own real-delay test).
    test(
      'a confirming read that genuinely never emits anything times out (distinct from an empty '
      'stream ending on its own)',
      () async {
        when(
          () => docRef.snapshots(includeMetadataChanges: true),
        ).thenAnswer((_) => StreamController<DocumentSnapshot<Map<String, dynamic>>>().stream);

        await expectLater(
          service.completeTransportConfirmed('patient-1', maxAttempts: 1),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains("didn't confirm after 1 attempts"))),
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('a stale/mismatched status keeps waiting rather than confirming early', () async {
      final staleMetadata = _MockMetadata();
      when(() => staleMetadata.hasPendingWrites).thenReturn(false);
      final staleSnapshot = _MockSnapshot();
      when(() => staleSnapshot.metadata).thenReturn(staleMetadata);
      when(() => staleSnapshot.exists).thenReturn(true);
      when(() => staleSnapshot.data()).thenReturn({'status': 'active'});

      when(() => docRef.snapshots(includeMetadataChanges: true)).thenAnswer(
        (_) => Stream.fromIterable([staleSnapshot, matchingSnapshot()]),
      );

      await service.completeTransportConfirmed('patient-1');
      verify(() => docRef.update(any())).called(1);
    });

    test('a snapshot with pending writes is skipped rather than treated as confirmed', () async {
      final pendingMetadata = _MockMetadata();
      when(() => pendingMetadata.hasPendingWrites).thenReturn(true);
      final pendingSnapshot = _MockSnapshot();
      when(() => pendingSnapshot.metadata).thenReturn(pendingMetadata);
      when(() => pendingSnapshot.exists).thenReturn(true);
      when(() => pendingSnapshot.data()).thenReturn({'status': 'completed'});

      when(() => docRef.snapshots(includeMetadataChanges: true)).thenAnswer(
        (_) => Stream.fromIterable([pendingSnapshot, matchingSnapshot()]),
      );

      await service.completeTransportConfirmed('patient-1');
      verify(() => docRef.update(any())).called(1);
    });
  });

  group('patientUploadServiceProvider', () {
    test('is wired to the shared firestore/functions/auth providers', () {
      final firestore = FakeFirebaseFirestore();
      final functions = _MockFirebaseFunctions();
      final auth = MockFirebaseAuth();
      final container = ProviderContainer(
        overrides: [
          firestoreProvider.overrideWithValue(firestore),
          firebaseFunctionsProvider.overrideWithValue(functions),
          firebaseAuthProvider.overrideWithValue(auth),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(patientUploadServiceProvider), isA<PatientUploadService>());
    });
  });
}
