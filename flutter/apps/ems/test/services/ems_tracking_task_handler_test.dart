import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:ems/services/ems_tracking_task_handler.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:mocktail/mocktail.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// See TESTING.md's "MockPlatformInterfaceMixin" note — confirmed for real
// via a throwaway probe test that swapping GeolocatorPlatform.instance for
// one of these actually intercepts Geolocator's static calls, rather than
// a real platform channel throwing first.
class _MockGeolocatorPlatform extends Mock with MockPlatformInterfaceMixin implements GeolocatorPlatform {}

class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

class _MockHttpsCallable extends Mock implements HttpsCallable {}

class _MockHttpsCallableResult<T> extends Mock implements HttpsCallableResult<T> {}

// The exact private port name flutter_foreground_task's own
// sendDataToMain looks up via IsolateNameServer — confirmed by reading
// its source (flutter_foreground_task.dart's `_kPortName`). Registering a
// real ReceivePort under this name lets a test observe sendDataToMain's
// actual effect directly, rather than trusting it happened unverified —
// sendDataToMain itself is pure Dart (IsolateNameServer lookup + a
// SendPort.send), no platform channel involved at all, so this works in
// a plain VM test with no mocking needed for it specifically.
const _foregroundTaskPortName = 'flutter_foreground_task/isolateComPort';

Position _position({double latitude = 45.4, double longitude = -75.7}) {
  return Position(
    longitude: longitude,
    latitude: latitude,
    timestamp: DateTime.now(),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(const LocationSettings());
    registerFallbackValue(<String, Object?>{});
  });

  late _MockGeolocatorPlatform geolocator;
  late GeolocatorPlatform realGeolocator;
  late _MockFirebaseFunctions functions;
  late _MockHttpsCallable callable;
  late ReceivePort mainIsolatePort;

  setUp(() {
    geolocator = _MockGeolocatorPlatform();
    realGeolocator = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = geolocator;

    functions = _MockFirebaseFunctions();
    callable = _MockHttpsCallable();
    when(() => functions.httpsCallable('publishEmsLocation')).thenReturn(callable);

    mainIsolatePort = ReceivePort();
    IsolateNameServer.registerPortWithName(mainIsolatePort.sendPort, _foregroundTaskPortName);
  });

  tearDown(() {
    GeolocatorPlatform.instance = realGeolocator;
    IsolateNameServer.removePortNameMapping(_foregroundTaskPortName);
    mainIsolatePort.close();
  });

  EmsTrackingTaskHandler handler() =>
      EmsTrackingTaskHandler(functions: functions, firebaseReady: true);

  void track(EmsTrackingTaskHandler h, String patientId) {
    h.onReceiveData(jsonEncode({'action': 'track', 'patientId': patientId}));
  }

  void untrack(EmsTrackingTaskHandler h, String patientId) {
    h.onReceiveData(jsonEncode({'action': 'untrack', 'patientId': patientId}));
  }

  group('onReceiveData', () {
    test('non-String data is ignored', () {
      final h = handler();
      expect(() => h.onReceiveData(42), returnsNormally);
      // Confirmed empty (not "tracking a String")  via onRepeatEvent's own
      // empty-set short circuit below.
      h.onRepeatEvent(DateTime.now());
      verifyNever(() => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')));
    });

    test('a payload missing patientId is ignored', () async {
      final h = handler();
      h.onReceiveData(jsonEncode({'action': 'track'}));
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verifyNever(() => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')));
    });

    test('untrack on a patient that was never tracked is a harmless no-op', () async {
      final h = handler();
      untrack(h, 'patient-1');
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verifyNever(() => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')));
    });

    test('track then untrack the same patient empties the tracked set again', () async {
      final h = handler();
      track(h, 'patient-1');
      untrack(h, 'patient-1');
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verifyNever(() => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')));
    });
  });

  group('onDestroy', () {
    test('clears the tracked set', () async {
      final h = handler();
      track(h, 'patient-1');
      await h.onDestroy(DateTime.now(), false);
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verifyNever(() => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')));
    });
  });

  group('onRepeatEvent -> _publishAllTracked', () {
    test('an empty tracked set short-circuits before touching Geolocator at all', () async {
      final h = handler();
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verifyNever(() => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')));
    });

    test('a Geolocator failure returns early — no signal sent, no publish attempted', () async {
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenThrow(Exception('no fix'));

      final h = handler();
      track(h, 'patient-1');
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();

      verifyNever(() => callable.call<Object?>(any()));
      // No fix -> the early `return` runs before sendDataToMain is ever
      // reached — confirm nothing arrived on the main-isolate port at
      // all, rather than just "the code we happened to check didn't run".
      await expectLater(
        mainIsolatePort.first.timeout(const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a successful fix reports the signal to the main isolate, then publishes every tracked patient', () async {
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      when(() => callable.call<Object?>(any())).thenAnswer((_) async => _MockHttpsCallableResult<Object?>());

      final h = handler();
      track(h, 'patient-1');
      track(h, 'patient-2');

      final signalReceived = mainIsolatePort.first;
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();

      expect(await signalReceived, emsFixReportSignal);
      verify(
        () => callable.call<Object?>(
          any(that: predicate<Map<Object?, Object?>>((m) => m['patientId'] == 'patient-1')),
        ),
      ).called(1);
      verify(
        () => callable.call<Object?>(
          any(that: predicate<Map<Object?, Object?>>((m) => m['patientId'] == 'patient-2')),
        ),
      ).called(1);
    });

    test("one tracked patient's publish failure doesn't stop the others from being attempted", () async {
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());

      var callCount = 0;
      when(() => callable.call<Object?>(any())).thenAnswer((invocation) async {
        callCount++;
        final args = invocation.positionalArguments.single as Map<Object?, Object?>;
        if (args['patientId'] == 'patient-1') throw Exception('publish failed');
        return _MockHttpsCallableResult<Object?>();
      });

      final h = handler();
      track(h, 'patient-1');
      track(h, 'patient-2');
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();

      expect(callCount, 2);
    });
  });

  group('onStart', () {
    test('resolves without throwing when firebaseReady bypasses the real bootstrap call', () async {
      final h = handler();
      await expectLater(h.onStart(DateTime.now(), TaskStarter.developer), completes);
    });
  });
}
