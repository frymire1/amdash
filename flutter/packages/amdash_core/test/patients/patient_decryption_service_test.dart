import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

class _MockHttpsCallable extends Mock implements HttpsCallable {}

class _MockHttpsCallableResult<T> extends Mock implements HttpsCallableResult<T> {}

const _emptyVitals = PatientVitals(heartRate: null, bloodPressure: '', oxygen: null, temperature: null);

Patient _patient({
  required String id,
  PatientField? name,
  PatientField? healthcareNumber,
}) {
  return Patient(
    id: id,
    name: name ?? PatientField.resolved('Plaintext Name'),
    healthcareNumber: healthcareNumber ?? PatientField.resolved('1234567890'),
    gender: '',
    age: null,
    vitals: _emptyVitals,
  );
}

PatientField _encrypted(String fingerprint) => PatientField.fromFirestore({'__enc': 1, 'ciphertext': fingerprint});

void main() {
  setUpAll(() {
    registerFallbackValue(<String, Object?>{});
  });

  group('PatientDecryptionService.decryptFields', () {
    late _MockFirebaseFunctions functions;
    late _MockHttpsCallable callable;
    late PatientDecryptionService service;

    setUp(() {
      functions = _MockFirebaseFunctions();
      callable = _MockHttpsCallable();
      when(() => functions.httpsCallable('decryptPatientFields')).thenReturn(callable);
      service = PatientDecryptionService(functions);
    });

    test('an empty patientIds list returns {} without calling the callable at all', () async {
      final result = await service.decryptFields(const []);
      expect(result, isEmpty);
      verifyNever(() => functions.httpsCallable(any()));
    });

    test('parses a successful response into one DecryptedPatientFields per result', () async {
      final response = _MockHttpsCallableResult<Map<Object?, Object?>>();
      when(() => response.data).thenReturn({
        'results': [
          {'patientId': 'p1', 'name': 'Jordan Smith', 'healthcareNumber': '1234567890'},
          {'patientId': 'p2', 'name': 'Alex Lee'},
        ],
      });
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => response);

      final result = await service.decryptFields(['p1', 'p2']);

      expect(result['p1']?.name, 'Jordan Smith');
      expect(result['p1']?.healthcareNumber, '1234567890');
      expect(result['p2']?.name, 'Alex Lee');
      expect(result['p2']?.healthcareNumber, isNull);
      verify(() => callable.call<Map<Object?, Object?>>({'patientIds': ['p1', 'p2']})).called(1);
    });

    test('returns {} when the response\'s results field is missing or not a List', () async {
      final response = _MockHttpsCallableResult<Map<Object?, Object?>>();
      when(() => response.data).thenReturn(<Object?, Object?>{});
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => response);

      final result = await service.decryptFields(['p1']);
      expect(result, isEmpty);
    });

    test('skips a result entry missing patientId rather than throwing', () async {
      final response = _MockHttpsCallableResult<Map<Object?, Object?>>();
      when(() => response.data).thenReturn({
        'results': [
          {'name': 'No id here'},
          {'patientId': 'p1', 'name': 'Jordan Smith'},
        ],
      });
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => response);

      final result = await service.decryptFields(['p1']);
      expect(result.keys, ['p1']);
    });
  });

  group('patientDecryptionServiceProvider', () {
    test('is wired to firebaseFunctionsProvider\'s current instance', () {
      final functions = _MockFirebaseFunctions();
      final container = ProviderContainer(
        overrides: [firebaseFunctionsProvider.overrideWithValue(functions)],
      );
      addTearDown(container.dispose);
      expect(container.read(patientDecryptionServiceProvider), isA<PatientDecryptionService>());
    });
  });

  group('PatientFieldCache', () {
    test('build() starts empty', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(patientFieldCacheProvider), isEmpty);
    });

    test('putAll merges entries into state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(patientFieldCacheProvider.notifier);

      notifier.putAll({'p1': const DecryptedPatientFields(name: 'Jordan Smith')});
      notifier.putAll({'p2': const DecryptedPatientFields(name: 'Alex Lee')});

      final state = container.read(patientFieldCacheProvider);
      expect(state.keys, containsAll(['p1', 'p2']));
      expect(state['p1']?.name, 'Jordan Smith');
    });

    test('putAll({}) is a no-op', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(patientFieldCacheProvider.notifier);

      notifier.putAll({'p1': const DecryptedPatientFields(name: 'Jordan Smith')});
      final before = container.read(patientFieldCacheProvider);
      notifier.putAll(const {});
      final after = container.read(patientFieldCacheProvider);

      // Same reference — the early-return path never called `state = ...`.
      expect(identical(before, after), true);
    });
  });

  group('pullMissingDecryptedPatientFields', () {
    late _MockFirebaseFunctions functions;
    late _MockHttpsCallable callable;
    late ProviderContainer container;
    late Ref ref;

    setUp(() {
      functions = _MockFirebaseFunctions();
      callable = _MockHttpsCallable();
      when(() => functions.httpsCallable('decryptPatientFields')).thenReturn(callable);
      container = ProviderContainer(
        overrides: [
          patientDecryptionServiceProvider.overrideWithValue(PatientDecryptionService(functions)),
        ],
      );
      final refCaptureProvider = Provider<Ref>((ref) => ref);
      ref = container.read(refCaptureProvider);
    });

    tearDown(() => container.dispose());

    test('a patient with no encrypted fields is never fetched', () async {
      final patient = _patient(id: 'p1'); // plaintext name/healthcareNumber by default
      pullMissingDecryptedPatientFields(ref, [patient]);
      await Future<void>.delayed(Duration.zero);

      verifyNever(() => callable.call<Map<Object?, Object?>>(any()));
    });

    test('a patient with an encrypted, never-cached field is fetched and cached', () async {
      final patient = _patient(id: 'p1', name: _encrypted('fp-1'));
      final response = _MockHttpsCallableResult<Map<Object?, Object?>>();
      when(() => response.data).thenReturn({
        'results': [
          {'patientId': 'p1', 'name': 'Jordan Smith'},
        ],
      });
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => response);

      pullMissingDecryptedPatientFields(ref, [patient]);
      await Future<void>.delayed(Duration.zero);

      verify(() => callable.call<Map<Object?, Object?>>({'patientIds': ['p1']})).called(1);
      final cached = container.read(patientFieldCacheProvider)['p1'];
      expect(cached?.name, 'Jordan Smith');
      // Filed under the fingerprint from the snapshot passed to this pull.
      expect(cached?.nameFingerprint, 'fp-1');
    });

    test('a patient whose cached fingerprint still matches is not re-fetched', () async {
      final patient = _patient(id: 'p1', name: _encrypted('fp-1'));
      container.read(patientFieldCacheProvider.notifier).putAll({
        'p1': const DecryptedPatientFields(name: 'Jordan Smith', nameFingerprint: 'fp-1'),
      });

      pullMissingDecryptedPatientFields(ref, [patient]);
      await Future<void>.delayed(Duration.zero);

      verifyNever(() => callable.call<Map<Object?, Object?>>(any()));
    });

    test('a patient whose cached fingerprint is stale (edited since) is re-fetched', () async {
      final patient = _patient(id: 'p1', name: _encrypted('fp-2'));
      container.read(patientFieldCacheProvider.notifier).putAll({
        'p1': const DecryptedPatientFields(name: 'Old Name', nameFingerprint: 'fp-1'),
      });
      final response = _MockHttpsCallableResult<Map<Object?, Object?>>();
      when(() => response.data).thenReturn({
        'results': [
          {'patientId': 'p1', 'name': 'New Name'},
        ],
      });
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => response);

      pullMissingDecryptedPatientFields(ref, [patient]);
      await Future<void>.delayed(Duration.zero);

      verify(() => callable.call<Map<Object?, Object?>>({'patientIds': ['p1']})).called(1);
      expect(container.read(patientFieldCacheProvider)['p1']?.name, 'New Name');
    });

    test('a failed pull is swallowed — no exception escapes, cache stays unchanged', () async {
      final patient = _patient(id: 'p1', name: _encrypted('fp-1'));
      when(() => callable.call<Map<Object?, Object?>>(any())).thenThrow(Exception('network error'));

      // Should not throw.
      pullMissingDecryptedPatientFields(ref, [patient]);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(patientFieldCacheProvider)['p1'], isNull);
    });

    test('a patient with no id (id: null) is never fetched', () async {
      final noIdPatient = Patient(
        name: _encrypted('fp-1'),
        healthcareNumber: PatientField.resolved(''),
        gender: '',
        age: null,
        vitals: _emptyVitals,
      );
      expect(noIdPatient.id, isNull);

      pullMissingDecryptedPatientFields(ref, [noIdPatient]);
      await Future<void>.delayed(Duration.zero);

      verifyNever(() => callable.call<Map<Object?, Object?>>(any()));
    });
  });

  group('withCachedDecryptedFields', () {
    late ProviderContainer container;
    late Ref ref;

    setUp(() {
      final functions = _MockFirebaseFunctions();
      final callable = _MockHttpsCallable();
      when(() => functions.httpsCallable(any())).thenReturn(callable);
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer(
        (_) async {
          final response = _MockHttpsCallableResult<Map<Object?, Object?>>();
          when(() => response.data).thenReturn(<Object?, Object?>{});
          return response;
        },
      );
      container = ProviderContainer(
        overrides: [
          patientDecryptionServiceProvider.overrideWithValue(PatientDecryptionService(functions)),
        ],
      );
      final refCaptureProvider = Provider<Ref>((ref) => ref);
      ref = container.read(refCaptureProvider);
    });

    tearDown(() => container.dispose());

    test('splices in a cached, fingerprint-matching value', () {
      container.read(patientFieldCacheProvider.notifier).putAll({
        'p1': const DecryptedPatientFields(name: 'Jordan Smith', nameFingerprint: 'fp-1'),
      });
      final patient = _patient(id: 'p1', name: _encrypted('fp-1'));

      final result = withCachedDecryptedFields(ref, [patient]);

      expect(result.single.name.plaintext, 'Jordan Smith');
      expect(result.single.name.isEncrypted, false);
    });

    test('leaves the field encrypted (unresolved) when nothing is cached yet', () {
      final patient = _patient(id: 'p1', name: _encrypted('fp-1'));

      final result = withCachedDecryptedFields(ref, [patient]);

      expect(result.single.name.isEncrypted, true);
      expect(result.single.name.plaintext, isNull);
    });

    test('leaves the field encrypted when the cached value\'s fingerprint is stale', () {
      container.read(patientFieldCacheProvider.notifier).putAll({
        'p1': const DecryptedPatientFields(name: 'Old Name', nameFingerprint: 'fp-old'),
      });
      final patient = _patient(id: 'p1', name: _encrypted('fp-new'));

      final result = withCachedDecryptedFields(ref, [patient]);

      expect(result.single.name.isEncrypted, true);
      expect(result.single.name.plaintext, isNull);
    });

    test('a plaintext (never-encrypted) field passes through untouched regardless of cache', () {
      final patient = _patient(id: 'p1'); // plaintext name by default

      final result = withCachedDecryptedFields(ref, [patient]);

      expect(result.single.name.plaintext, 'Plaintext Name');
    });
  });
}
