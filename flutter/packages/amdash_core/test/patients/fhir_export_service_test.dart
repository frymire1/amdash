import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

class _MockHttpsCallable extends Mock implements HttpsCallable {}

class _MockHttpsCallableResult<T> extends Mock implements HttpsCallableResult<T> {}

// FirebaseFunctionsException's own constructor requires a non-null
// `message` (confirmed — no way to construct a real null-message instance
// through the public API), but `_messageFor`'s `error.message ?? "..."`
// fallback exists for exactly that case (presumably reachable via some
// native-SDK deserialization path this package doesn't expose). A mocktail
// mock sidesteps the constructor entirely to exercise it.
class _MockFirebaseFunctionsException extends Mock implements FirebaseFunctionsException {}

Map<String, Object?> _observation(String loincCode, num value) {
  return {
    'resourceType': 'Observation',
    'code': {
      'coding': [
        {'code': loincCode},
      ],
    },
    'valueQuantity': {'value': value},
  };
}

void main() {
  setUpAll(() {
    registerFallbackValue(<String, Object?>{});
  });

  group('FhirExportException', () {
    test('toString() returns the message directly', () {
      const exception = FhirExportException('Something went wrong.');
      expect(exception.toString(), 'Something went wrong.');
    });
  });

  group('FhirExportResult', () {
    test('holds exactly what it was constructed with', () {
      // Not `const` — a compile-time-const construction never actually
      // "runs" the constructor at runtime, so it wouldn't register as
      // covering the constructor's own declaration line.
      final result = FhirExportResult(filePath: '/tmp/export.json', bundle: {'resourceType': 'Bundle'});
      expect(result.filePath, '/tmp/export.json');
      expect(result.bundle, {'resourceType': 'Bundle'});
    });
  });

  group('latestObservationValue', () {
    test('null when the bundle has no entry list at all', () {
      expect(latestObservationValue(const {}, loincHeartRate), isNull);
    });

    test('null when nothing in the bundle matches the requested LOINC code', () {
      final bundle = {
        'entry': [
          {'resource': _observation('1234-5', 99)},
        ],
      };
      expect(latestObservationValue(bundle, loincHeartRate), isNull);
    });

    test('skips non-Observation resources', () {
      final bundle = {
        'entry': [
          {
            'resource': {'resourceType': 'Patient'},
          },
          {'resource': _observation(loincHeartRate, 80)},
        ],
      };
      expect(latestObservationValue(bundle, loincHeartRate), 80);
    });

    test('returns the LAST matching entry (bundle is oldest-first, so this is most recent)', () {
      final bundle = {
        'entry': [
          {'resource': _observation(loincHeartRate, 70)},
          {'resource': _observation(loincHeartRate, 95)},
        ],
      };
      expect(latestObservationValue(bundle, loincHeartRate), 95);
    });

    test('a non-numeric valueQuantity.value does not count as a reading', () {
      final bundle = {
        'entry': [
          {'resource': _observation(loincHeartRate, 70)},
          {
            'resource': {
              'resourceType': 'Observation',
              'code': {
                'coding': [
                  {'code': loincHeartRate},
                ],
              },
              'valueQuantity': {'value': 'Unknown'},
            },
          },
        ],
      };
      // The malformed second entry is skipped; the last *valid* reading
      // (70) is what's returned, not null.
      expect(latestObservationValue(bundle, loincHeartRate), 70);
    });
  });

  group('exportPatientFhirBundle', () {
    late _MockFirebaseFunctions functions;
    late _MockHttpsCallable callable;

    setUp(() {
      functions = _MockFirebaseFunctions();
      callable = _MockHttpsCallable();
      when(() => functions.httpsCallable('exportPatientFhirBundle')).thenReturn(callable);
    });

    test('wraps a FirebaseFunctionsException in FhirExportException using its own message', () async {
      when(() => callable.call<Map<Object?, Object?>>(any())).thenThrow(
        FirebaseFunctionsException(message: 'Custom failure message', code: 'internal'),
      );

      await expectLater(
        exportPatientFhirBundle(functions, 'patient-1'),
        throwsA(isA<FhirExportException>().having((e) => e.message, 'message', 'Custom failure message')),
      );
      expect(debugLastExportError, isA<FhirExportException>());
    });

    test('falls back to a generic message when the exception carries none', () async {
      final exception = _MockFirebaseFunctionsException();
      when(() => exception.message).thenReturn(null);
      // _callWithCompletionRetry reads .code before _messageFor ever reads
      // .message (to decide whether this is retryable) — needs stubbing
      // too, or mocktail's unstubbed-getter default trips a type error
      // trying to satisfy `code`'s non-nullable String return type.
      when(() => exception.code).thenReturn('internal');
      when(() => callable.call<Map<Object?, Object?>>(any())).thenThrow(exception);

      await expectLater(
        exportPatientFhirBundle(functions, 'patient-1'),
        throwsA(
          isA<FhirExportException>().having(
            (e) => e.message,
            'message',
            "Couldn't export this patient's FHIR record. Please try again.",
          ),
        ),
      );
    });

    test('a successful response is decoded/re-encoded before reaching the platform-specific save step', () async {
      final response = _MockHttpsCallableResult<Map<Object?, Object?>>();
      when(() => response.data).thenReturn({
        'bundle': {'resourceType': 'Bundle', 'entry': <Object?>[]},
      });
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => response);

      // FileSaver.instance.saveFile itself is excluded from coverage (see
      // that block's own comment) since it's a real platform-channel call
      // with no fake in a Dart VM test — this only proves the callable
      // response was successfully decoded and re-encoded (this function's
      // lines 81-83) on the way there, not that a file actually got saved.
      await expectLater(exportPatientFhirBundle(functions, 'patient-1'), throwsA(anything));
    });

    test('a non-"not yet completed" failed-precondition is rethrown immediately, no retry', () async {
      var callCount = 0;
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) {
        callCount++;
        throw FirebaseFunctionsException(
          code: 'failed-precondition',
          message: 'FHIR export is not enabled for this organization.',
        );
      });

      await expectLater(exportPatientFhirBundle(functions, 'patient-1'), throwsA(isA<FhirExportException>()));
      expect(callCount, 1);
    });

    test('a non-failed-precondition error code is rethrown immediately, no retry', () async {
      var callCount = 0;
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) {
        callCount++;
        throw FirebaseFunctionsException(code: 'permission-denied', message: 'nope');
      });

      await expectLater(exportPatientFhirBundle(functions, 'patient-1'), throwsA(isA<FhirExportException>()));
      expect(callCount, 1);
    });

    // Real ~2s delays between attempts (see _callWithCompletionRetry's own
    // comment) — this repo has no fake-async dependency to skip them, and
    // adding one just for this file isn't worth it. Kept to exactly the
    // "retries then still fails" case so it only pays the delay once
    // (2 delays between 3 attempts), not twice.
    test(
      'retries the "not yet completed" precondition up to 3 attempts, then rethrows',
      () async {
        var callCount = 0;
        when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) {
          callCount++;
          throw FirebaseFunctionsException(
            code: 'failed-precondition',
            message: "This patient's transport must be marked complete before it can be exported.",
          );
        });

        await expectLater(exportPatientFhirBundle(functions, 'patient-1'), throwsA(isA<FhirExportException>()));
        expect(callCount, 3);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('fhirExportFunctionsProvider', () {
    test('is wired to firebaseFunctionsProvider\'s current instance', () {
      final functions = _MockFirebaseFunctions();
      final container = ProviderContainer(
        overrides: [firebaseFunctionsProvider.overrideWithValue(functions)],
      );
      addTearDown(container.dispose);

      expect(container.read(fhirExportFunctionsProvider), same(functions));
    });
  });
}
