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
  late StreamController<Position> positionController;

  setUp(() {
    geolocator = _MockGeolocatorPlatform();
    realGeolocator = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = geolocator;

    // Single-subscription, not broadcast — matches the real isolate's own
    // exactly-one-subscriber model (_ensurePositionStream). Events added
    // before the handler's own lazy/eager listen() call are buffered and
    // delivered once it does subscribe, same as a real Stream.
    positionController = StreamController<Position>();
    when(
      () => geolocator.getPositionStream(locationSettings: any(named: 'locationSettings')),
    ).thenAnswer((_) => positionController.stream);

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
    positionController.close();
  });

  // Mirrors the real lifecycle exactly — the OS/plugin always calls
  // onStart before any onRepeatEvent ever fires (emsTrackingTaskCallback),
  // and onStart is what establishes the position stream subscription now
  // (see _ensurePositionStream's own doc comment on why this moved off a
  // per-tick one-shot request). Async so every call site can await it.
  Future<EmsTrackingTaskHandler> handler() async {
    final h = EmsTrackingTaskHandler(functions: functions, firebaseReady: true);
    await h.onStart(DateTime.now(), TaskStarter.developer);
    return h;
  }

  void track(EmsTrackingTaskHandler h, String patientId) {
    h.onReceiveData(jsonEncode({'action': 'track', 'patientId': patientId}));
  }

  void untrack(EmsTrackingTaskHandler h, String patientId) {
    h.onReceiveData(jsonEncode({'action': 'untrack', 'patientId': patientId}));
  }

  void setAmbulanceId(EmsTrackingTaskHandler h, String ambulanceId) {
    h.onReceiveData(jsonEncode({'action': 'setAmbulanceId', 'ambulanceId': ambulanceId}));
  }

  void clearAmbulanceId(EmsTrackingTaskHandler h) {
    h.onReceiveData(jsonEncode({'action': 'clearAmbulanceId'}));
  }

  // Pushes a fix through the stream and lets it actually reach
  // _lastPosition before returning — the stream delivers asynchronously
  // (a real event-loop turn), never synchronously inline with add().
  Future<void> deliverPosition(Position position) async {
    positionController.add(position);
    await pumpEventQueue();
  }

  group('onReceiveData', () {
    test('non-String data is ignored', () async {
      final h = await handler();
      expect(() => h.onReceiveData(42), returnsNormally);
      // Confirmed empty (not "tracking a String") via onRepeatEvent's own
      // empty-set short circuit below.
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verifyNever(() => callable.call<Object?>(any()));
    });

    test('a payload missing patientId is ignored', () async {
      final h = await handler();
      h.onReceiveData(jsonEncode({'action': 'track'}));
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verifyNever(() => callable.call<Object?>(any()));
    });

    test('untrack on a patient that was never tracked is a harmless no-op', () async {
      final h = await handler();
      untrack(h, 'patient-1');
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verifyNever(() => callable.call<Object?>(any()));
    });

    test('track then untrack the same patient empties the tracked set again', () async {
      final h = await handler();
      track(h, 'patient-1');
      untrack(h, 'patient-1');
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verifyNever(() => callable.call<Object?>(any()));
    });
  });

  group('onDestroy', () {
    test('clears the tracked set', () async {
      final h = await handler();
      track(h, 'patient-1');
      await h.onDestroy(DateTime.now(), false);
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verifyNever(() => callable.call<Object?>(any()));
    });

    test('cancels the position stream subscription and clears the last-known position', () async {
      final h = await handler();
      await deliverPosition(_position());
      expect(positionController.hasListener, true);

      await h.onDestroy(DateTime.now(), false);
      await pumpEventQueue();

      // The real isolate never calls onRepeatEvent again after onDestroy
      // (the whole isolate is being torn down), so there's no realistic
      // way to observe _lastPosition's own clearing via another tick —
      // cancelling the subscription is the externally-observable half of
      // this cleanup, confirmed directly; _lastPosition's own reset is
      // exercised (for coverage) by this same call, just not separately
      // asserted on.
      expect(positionController.hasListener, false);
    });
  });

  group('onRepeatEvent -> _publishAllTracked', () {
    test('an empty tracked set short-circuits before ever subscribing to the position stream', () async {
      final h = EmsTrackingTaskHandler(functions: functions, firebaseReady: true);
      // Deliberately not calling onStart here — this test's own point is
      // that _publishAllTracked's own early return (nothing tracked, no
      // ambulance) fires before _ensurePositionStream ever runs, so
      // getPositionStream should never be touched at all.
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verifyNever(() => geolocator.getPositionStream(locationSettings: any(named: 'locationSettings')));
    });

    test('no position delivered yet returns early — no signal sent, no publish attempted', () async {
      final h = await handler();
      track(h, 'patient-1');
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();

      verifyNever(() => callable.call<Object?>(any()));
      // The early `return` runs before sendDataToMain is ever reached —
      // confirm nothing arrived on the main-isolate port at all, rather
      // than just "the code we happened to check didn't run".
      await expectLater(
        mainIsolatePort.first.timeout(const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a successful fix reports the signal to the main isolate, then publishes every tracked patient', () async {
      when(() => callable.call<Object?>(any())).thenAnswer((_) async => _MockHttpsCallableResult<Object?>());

      final h = await handler();
      await deliverPosition(_position());
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
      var callCount = 0;
      when(() => callable.call<Object?>(any())).thenAnswer((invocation) async {
        callCount++;
        final args = invocation.positionalArguments.single as Map<Object?, Object?>;
        if (args['patientId'] == 'patient-1') throw Exception('publish failed');
        return _MockHttpsCallableResult<Object?>();
      });

      final h = await handler();
      await deliverPosition(_position());
      track(h, 'patient-1');
      track(h, 'patient-2');
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();

      expect(callCount, 2);
    });

    test('a later fix updates what the next tick publishes', () async {
      when(() => callable.call<Object?>(any())).thenAnswer((_) async => _MockHttpsCallableResult<Object?>());

      final h = await handler();
      await deliverPosition(_position(latitude: 1, longitude: 1));
      track(h, 'patient-1');
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();

      await deliverPosition(_position(latitude: 2, longitude: 2));
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();

      verify(
        () => callable.call<Object?>(
          any(that: predicate<Map<Object?, Object?>>((m) => m['latitude'] == 2 && m['longitude'] == 2)),
        ),
      ).called(1);
    });

    test('a position-stream error is tolerated — a later real fix still gets published', () async {
      when(() => callable.call<Object?>(any())).thenAnswer((_) async => _MockHttpsCallableResult<Object?>());

      final h = await handler();
      track(h, 'patient-1');

      // Reaching here without an unhandled-error test failure is part of
      // the assertion — the stream's own onError handler is what's
      // supposed to swallow this.
      positionController.addError(Exception('provider unavailable'));
      await pumpEventQueue();
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verifyNever(() => callable.call<Object?>(any()));

      // A single-subscription stream that's already errored can still
      // deliver further data events afterward (addError doesn't close
      // it) — confirms this isolate keeps working on the next real fix
      // rather than being permanently wedged by one bad event.
      await deliverPosition(_position());
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      verify(() => callable.call<Object?>(any())).called(1);
    });
  });

  group('_ensurePositionStream', () {
    test('only subscribes once, even across onStart and multiple onRepeatEvent ticks', () async {
      final h = await handler();
      track(h, 'patient-1');
      await deliverPosition(_position());
      when(() => callable.call<Object?>(any())).thenAnswer((_) async => _MockHttpsCallableResult<Object?>());

      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();
      h.onRepeatEvent(DateTime.now());
      await pumpEventQueue();

      verify(() => geolocator.getPositionStream(locationSettings: any(named: 'locationSettings'))).called(1);
    });
  });

  group('onRepeatEvent -> _publishAllTracked ambulance publishing', () {
    late _MockHttpsCallable ambulanceCallable;

    setUp(() {
      ambulanceCallable = _MockHttpsCallable();
      when(() => functions.httpsCallable('publishAmbulanceLocation')).thenReturn(ambulanceCallable);
      when(
        () => ambulanceCallable.call<Object?>(any()),
      ).thenAnswer((_) async => _MockHttpsCallableResult<Object?>());
    });

    test('an identified ambulance with no tracked patients publishes on the very first tick', () async {
      final h = await handler();
      await deliverPosition(_position());
      setAmbulanceId(h, 'Unit 5');

      h.onRepeatEvent(DateTime(2026));
      await pumpEventQueue();

      verify(
        () => ambulanceCallable.call<Object?>(
          any(
            that: predicate<Map<Object?, Object?>>(
              (m) => m['ambulanceId'] == 'Unit 5' && m['isTransporting'] == false,
            ),
          ),
        ),
      ).called(1);
      verifyNever(() => callable.call<Object?>(any()));
    });

    test('a second tick before the idle interval elapses is a total no-op (no publish attempted at all)', () async {
      final h = await handler();
      await deliverPosition(_position());
      setAmbulanceId(h, 'Unit 5');
      final t0 = DateTime(2026);
      h.onRepeatEvent(t0);
      await pumpEventQueue();

      h.onRepeatEvent(t0.add(const Duration(seconds: 30)));
      await pumpEventQueue();

      // Still due to run just once — the second tick's own ambulanceDue
      // check itself returns false, so _publishAllTracked's early-return
      // fires first.
      verify(() => ambulanceCallable.call<Object?>(any())).called(1);
    });

    test('a tick once the idle interval has elapsed republishes', () async {
      final h = await handler();
      await deliverPosition(_position());
      setAmbulanceId(h, 'Unit 5');
      final t0 = DateTime(2026);
      h.onRepeatEvent(t0);
      await pumpEventQueue();

      h.onRepeatEvent(t0.add(const Duration(seconds: 61)));
      await pumpEventQueue();

      verify(() => ambulanceCallable.call<Object?>(any())).called(2);
    });

    test('clearAmbulanceId stops further ambulance publishing entirely', () async {
      final h = await handler();
      await deliverPosition(_position());
      setAmbulanceId(h, 'Unit 5');
      final t0 = DateTime(2026);
      h.onRepeatEvent(t0);
      await pumpEventQueue();

      clearAmbulanceId(h);
      h.onRepeatEvent(t0.add(const Duration(seconds: 61)));
      await pumpEventQueue();

      verify(() => ambulanceCallable.call<Object?>(any())).called(1);
    });

    test('a tracked patient plus an identified ambulance publishes both, with isTransporting true', () async {
      when(() => callable.call<Object?>(any())).thenAnswer((_) async => _MockHttpsCallableResult<Object?>());

      final h = await handler();
      await deliverPosition(_position());
      track(h, 'patient-1');
      setAmbulanceId(h, 'Unit 9');

      h.onRepeatEvent(DateTime(2026));
      await pumpEventQueue();

      verify(
        () => ambulanceCallable.call<Object?>(
          any(
            that: predicate<Map<Object?, Object?>>(
              (m) => m['ambulanceId'] == 'Unit 9' && m['isTransporting'] == true,
            ),
          ),
        ),
      ).called(1);
      verify(
        () => callable.call<Object?>(
          any(that: predicate<Map<Object?, Object?>>((m) => m['patientId'] == 'patient-1')),
        ),
      ).called(1);
    });

    test('a publishAmbulanceLocation failure is swallowed — the per-patient publishes still succeed', () async {
      when(() => ambulanceCallable.call<Object?>(any())).thenThrow(Exception('publish failed'));
      when(() => callable.call<Object?>(any())).thenAnswer((_) async => _MockHttpsCallableResult<Object?>());

      final h = await handler();
      await deliverPosition(_position());
      track(h, 'patient-1');
      setAmbulanceId(h, 'Unit 9');

      // Reaching here without throwing is part of the assertion.
      h.onRepeatEvent(DateTime(2026));
      await pumpEventQueue();

      verify(
        () => callable.call<Object?>(
          any(that: predicate<Map<Object?, Object?>>((m) => m['patientId'] == 'patient-1')),
        ),
      ).called(1);
    });
  });

  group('onStart', () {
    test('resolves without throwing when firebaseReady bypasses the real bootstrap call', () async {
      final h = EmsTrackingTaskHandler(functions: functions, firebaseReady: true);
      await expectLater(h.onStart(DateTime.now(), TaskStarter.developer), completes);
    });

    test('subscribes to the position stream', () async {
      final h = EmsTrackingTaskHandler(functions: functions, firebaseReady: true);
      await h.onStart(DateTime.now(), TaskStarter.developer);

      verify(() => geolocator.getPositionStream(locationSettings: any(named: 'locationSettings'))).called(1);
    });
  });
}
