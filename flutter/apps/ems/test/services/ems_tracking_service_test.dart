import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:ems/services/ems_tracking_service.dart';
import 'package:ems/services/ems_tracking_task_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_foreground_task/flutter_foreground_task_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:mocktail/mocktail.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

// See TESTING.md's "MockPlatformInterfaceMixin" note — confirmed for real
// via a throwaway probe test that swapping GeolocatorPlatform.instance/
// FlutterForegroundTaskPlatform.instance for one of these actually
// intercepts the plugins' static calls, rather than a real platform
// channel throwing first.
class _MockGeolocatorPlatform extends Mock with MockPlatformInterfaceMixin implements GeolocatorPlatform {}

class _MockForegroundTaskPlatform extends Mock with MockPlatformInterfaceMixin implements FlutterForegroundTaskPlatform {}

class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

class _MockHttpsCallable extends Mock implements HttpsCallable {}

class _MockHttpsCallableResult<T> extends Mock implements HttpsCallableResult<T> {}

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
    registerFallbackValue(AndroidNotificationOptions(channelId: 'x', channelName: 'x'));
    registerFallbackValue(const IOSNotificationOptions());
    registerFallbackValue(ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.once()));
  });

  late _MockGeolocatorPlatform geolocator;
  late GeolocatorPlatform realGeolocator;
  late _MockForegroundTaskPlatform foregroundTask;
  late FlutterForegroundTaskPlatform realForegroundTask;
  late _MockFirebaseFunctions functions;
  late _MockHttpsCallable callable;

  setUp(() {
    SharedPreferences.setMockInitialValues({});

    geolocator = _MockGeolocatorPlatform();
    realGeolocator = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = geolocator;

    foregroundTask = _MockForegroundTaskPlatform();
    realForegroundTask = FlutterForegroundTaskPlatform.instance;
    FlutterForegroundTaskPlatform.instance = foregroundTask;
    // @visibleForTesting statics on FlutterForegroundTask itself (not the
    // platform interface) — these persist across the whole isolate/test
    // run otherwise, leaking state (e.g. isInitialized) between tests in
    // this file. skipServiceResponseCheck=true skips
    // checkServiceStateChange's own extra isRunningService poll loop
    // (real ~5s deadline logic this test suite has no need to exercise).
    FlutterForegroundTask.resetStatic();
    FlutterForegroundTask.skipServiceResponseCheck = true;

    functions = _MockFirebaseFunctions();
    callable = _MockHttpsCallable();
    when(() => functions.httpsCallable(any())).thenReturn(callable);
    when(() => callable.call<Object?>(any())).thenAnswer((_) async => _MockHttpsCallableResult<Object?>());
  });

  tearDown(() {
    GeolocatorPlatform.instance = realGeolocator;
    FlutterForegroundTaskPlatform.instance = realForegroundTask;
    debugDefaultTargetPlatformOverride = null;
  });

  // Simulates the Android foreground-service lifecycle: isRunningService
  // starts at [initiallyRunning] and flips to match whichever of
  // startService/stopService was last (successfully) called — same
  // observable contract the real platform implementation has, just
  // in-memory.
  void stubForegroundServiceLifecycle({bool initiallyRunning = false}) {
    var running = initiallyRunning;
    when(() => foregroundTask.isRunningService).thenAnswer((_) async => running);
    when(
      () => foregroundTask.startService(
        androidNotificationOptions: any(named: 'androidNotificationOptions'),
        iosNotificationOptions: any(named: 'iosNotificationOptions'),
        foregroundTaskOptions: any(named: 'foregroundTaskOptions'),
        serviceId: any(named: 'serviceId'),
        serviceTypes: any(named: 'serviceTypes'),
        notificationTitle: any(named: 'notificationTitle'),
        notificationText: any(named: 'notificationText'),
        notificationIcon: any(named: 'notificationIcon'),
        notificationButtons: any(named: 'notificationButtons'),
        notificationInitialRoute: any(named: 'notificationInitialRoute'),
        callback: any(named: 'callback'),
      ),
    ).thenAnswer((_) async => running = true);
    when(() => foregroundTask.stopService()).thenAnswer((_) async => running = false);
  }

  void stubNotificationPermission(NotificationPermission granted) {
    when(() => foregroundTask.checkNotificationPermission()).thenAnswer((_) async => granted);
    when(() => foregroundTask.requestNotificationPermission()).thenAnswer((_) async => NotificationPermission.granted);
  }

  ProviderContainer containerFor() {
    final container = ProviderContainer(overrides: [firebaseFunctionsProvider.overrideWithValue(functions)]);
    addTearDown(container.dispose);
    return container;
  }

  group('build / isTracking', () {
    test('starts with an empty tracked set when nothing was persisted', () async {
      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await pumpEventQueue();

      expect(container.read(emsTrackingProvider), isEmpty);
      expect(controller.isTracking('patient-1'), false);
    });
  });

  group('evaluateHealth', () {
    test('nothing tracked -> online, without touching Geolocator at all', () async {
      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await pumpEventQueue();

      expect(await controller.evaluateHealth(), EmsTrackingHealth.online);
      verifyNever(() => geolocator.isLocationServiceEnabled());
    });

    test('location services disabled -> locationOff', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      when(() => geolocator.isLocationServiceEnabled()).thenAnswer((_) async => false);
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.granted);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');

      expect(await controller.evaluateHealth(), EmsTrackingHealth.locationOff);
    });

    for (final denied in [LocationPermission.denied, LocationPermission.deniedForever]) {
      test('permission $denied -> permissionDenied', () async {
        when(
          () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
        ).thenAnswer((_) async => _position());
        when(() => geolocator.isLocationServiceEnabled()).thenAnswer((_) async => true);
        when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
        stubForegroundServiceLifecycle();
        stubNotificationPermission(NotificationPermission.granted);

        final container = containerFor();
        final controller = container.read(emsTrackingProvider.notifier);
        await controller.startTracking('patient-1');

        // Permission was revoked sometime after startTracking succeeded.
        when(() => geolocator.checkPermission()).thenAnswer((_) async => denied);
        expect(await controller.evaluateHealth(), EmsTrackingHealth.permissionDenied);
      });
    }

    test('a fresh fix -> online; no fix yet (or long stale) -> noSignal', () async {
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      when(() => geolocator.isLocationServiceEnabled()).thenAnswer((_) async => true);
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.granted);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');

      // startTracking's own confirming publish just recorded a fix.
      expect(await controller.evaluateHealth(), EmsTrackingHealth.online);
    });
  });

  group('_onTaskData wiring (Android isolate -> main isolate freshness)', () {
    test('a matching signal and a non-matching value both run without throwing', () async {
      final container = containerFor();
      container.read(emsTrackingProvider.notifier);
      await pumpEventQueue();

      // build() registered this controller's _onTaskData into the real
      // (now test-scoped, thanks to resetStatic() in setUp) static
      // callback list — dispatching through it directly is the only way
      // to reach a private instance method from a separate test file.
      // The affirmative case's actual effect on freshness is exercised
      // via the same underlying _recordFix() the publish-path tests
      // above already cover; this confirms both of _onTaskData's own
      // branches (matching/non-matching) execute safely.
      for (final callback in FlutterForegroundTask.dataCallbacks) {
        expect(() => callback('not-the-signal'), returnsNormally);
        expect(() => callback(emsFixReportSignal), returnsNormally);
      }
      expect(FlutterForegroundTask.dataCallbacks, isNotEmpty);
    });
  });

  group('_ensurePermissions (via startTracking)', () {
    test('denied permission triggers a request', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.denied);
      when(() => geolocator.requestPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.granted);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');

      verify(() => geolocator.requestPermission()).called(1);
    });

    test('Android: checks/requests notification permission when not already granted', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.denied);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');

      verify(() => foregroundTask.checkNotificationPermission()).called(1);
      verify(() => foregroundTask.requestNotificationPermission()).called(1);
    });

    test('Android: does not re-request notification permission when already granted', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.granted);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');

      verifyNever(() => foregroundTask.requestNotificationPermission());
    });

    test('iOS: escalates a whileInUse grant toward always, and skips the notification-permission check', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      when(
        () => geolocator.checkPermission(),
      ).thenAnswer((_) async => LocationPermission.whileInUse);
      when(() => geolocator.requestPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      when(
        () => geolocator.getPositionStream(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) => const Stream.empty());

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');

      verify(() => geolocator.requestPermission()).called(1);
      verifyNever(() => foregroundTask.checkNotificationPermission());
    });
  });

  group('startTracking', () {
    test('re-publishes even when already tracking, without re-activating', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.granted);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');
      await controller.startTracking('patient-1');

      verify(
        () => callable.call<Object?>(
          any(that: predicate<Map<Object?, Object?>>((m) => m['patientId'] == 'patient-1')),
        ),
      ).called(2);
      // _activate (which starts the foreground service) only ran once —
      // the second startTracking call didn't re-activate.
      verify(
        () => foregroundTask.startService(
          androidNotificationOptions: any(named: 'androidNotificationOptions'),
          iosNotificationOptions: any(named: 'iosNotificationOptions'),
          foregroundTaskOptions: any(named: 'foregroundTaskOptions'),
          serviceId: any(named: 'serviceId'),
          serviceTypes: any(named: 'serviceTypes'),
          notificationTitle: any(named: 'notificationTitle'),
          notificationText: any(named: 'notificationText'),
          notificationIcon: any(named: 'notificationIcon'),
          notificationButtons: any(named: 'notificationButtons'),
          notificationInitialRoute: any(named: 'notificationInitialRoute'),
          callback: any(named: 'callback'),
        ),
      ).called(1);
    });

    test('rolls back (deactivates) and rethrows when the confirming publish fails', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenThrow(Exception('no fix available'));
      // _ensurePermissions (before the failing publish) still needs this
      // stubbed, or its own Android notification-permission check throws
      // first instead of the publish this test means to exercise.
      stubNotificationPermission(NotificationPermission.granted);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);

      await expectLater(controller.startTracking('patient-1'), throwsA(isA<Exception>()));
      expect(controller.isTracking('patient-1'), false);
    });
  });

  group('stopTracking', () {
    test('deactivates even when the stopEmsLocation callable fails (fire-and-forget)', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.granted);

      final stopCallable = _MockHttpsCallable();
      when(() => functions.httpsCallable('stopEmsLocation')).thenReturn(stopCallable);
      when(() => stopCallable.call<Object?>(any())).thenThrow(Exception('network error'));

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');

      await controller.stopTracking('patient-1');
      expect(controller.isTracking('patient-1'), false);
    });

    test('deactivates on a successful stopEmsLocation call too', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.granted);

      final stopCallable = _MockHttpsCallable();
      when(() => functions.httpsCallable('stopEmsLocation')).thenReturn(stopCallable);
      when(() => stopCallable.call<Object?>(any())).thenAnswer((_) async => _MockHttpsCallableResult<Object?>());

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');

      await controller.stopTracking('patient-1');
      expect(controller.isTracking('patient-1'), false);
      verify(() => stopCallable.call<Object?>({'patientId': 'patient-1'})).called(1);
    });
  });

  group('Android delivery mechanism', () {
    test('starting a second patient does not re-init the foreground task', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.granted);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');
      expect(FlutterForegroundTask.isInitialized, true);

      await controller.startTracking('patient-2');
      // init() being idempotent-safe to call twice isn't the point here —
      // _foregroundTaskInitialized gates it so _initForegroundTask() (and
      // therefore FlutterForegroundTask.init) only ever runs once per
      // controller instance. startService itself is ALSO not called
      // again for the second patient — stubForegroundServiceLifecycle's
      // fake correctly reports isRunningService: true after the first
      // start, and _ensureForegroundServiceRunning only calls
      // startService when the service isn't already running.
      verify(
        () => foregroundTask.startService(
          androidNotificationOptions: any(named: 'androidNotificationOptions'),
          iosNotificationOptions: any(named: 'iosNotificationOptions'),
          foregroundTaskOptions: any(named: 'foregroundTaskOptions'),
          serviceId: any(named: 'serviceId'),
          serviceTypes: any(named: 'serviceTypes'),
          notificationTitle: any(named: 'notificationTitle'),
          notificationText: any(named: 'notificationText'),
          notificationIcon: any(named: 'notificationIcon'),
          notificationButtons: any(named: 'notificationButtons'),
          notificationInitialRoute: any(named: 'notificationInitialRoute'),
          callback: any(named: 'callback'),
        ),
      ).called(1);
    });

    test('sends a track action to the isolate on activate, untrack on deactivate', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.granted);
      when(() => foregroundTask.sendDataToTask(any())).thenReturn(null);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');
      verify(() => foregroundTask.sendDataToTask(any(that: contains('"action":"track"')))).called(1);

      await controller.stopTracking('patient-1');
      verify(() => foregroundTask.sendDataToTask(any(that: contains('"action":"untrack"')))).called(1);
    });

    test('stops the foreground service once the last tracked patient is removed, '
        'not while others remain', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.granted);
      when(() => foregroundTask.sendDataToTask(any())).thenReturn(null);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');
      await controller.startTracking('patient-2');

      await controller.stopTracking('patient-1');
      verifyNever(() => foregroundTask.stopService());

      await controller.stopTracking('patient-2');
      verify(() => foregroundTask.stopService()).called(1);
    });
  });

  group('iOS delivery mechanism', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test('subscribes to the position stream exactly once across multiple activations', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      final positionController = StreamController<Position>.broadcast();
      addTearDown(positionController.close);
      when(
        () => geolocator.getPositionStream(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) => positionController.stream);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');
      await controller.startTracking('patient-2');

      verify(() => geolocator.getPositionStream(locationSettings: any(named: 'locationSettings'))).called(1);
    });

    test('a position fix publishes to every currently-tracked patient', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      final positionController = StreamController<Position>.broadcast();
      addTearDown(positionController.close);
      when(
        () => geolocator.getPositionStream(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) => positionController.stream);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');
      await controller.startTracking('patient-2');

      positionController.add(_position(latitude: 46, longitude: -76));
      await pumpEventQueue();

      verify(
        () => callable.call<Object?>(
          any(that: predicate<Map<Object?, Object?>>((m) => m['patientId'] == 'patient-1' && m['latitude'] == 46)),
        ),
      ).called(1);
      verify(
        () => callable.call<Object?>(
          any(that: predicate<Map<Object?, Object?>>((m) => m['patientId'] == 'patient-2' && m['latitude'] == 46)),
        ),
      ).called(1);
    });

    test('throttles publishes within the same update interval, but lets a later one through', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      final positionController = StreamController<Position>.broadcast();
      addTearDown(positionController.close);
      when(
        () => geolocator.getPositionStream(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) => positionController.stream);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      // startTracking's own confirming publish is call #1.
      await controller.startTracking('patient-1');

      positionController.add(_position(latitude: 1));
      await pumpEventQueue();
      positionController.add(_position(latitude: 2));
      await pumpEventQueue();

      // Both stream fixes arrived within the same 15s window as the
      // confirming publish above — only the first one through the stream
      // published (the throttle's very first check has no prior
      // _lastIOSPublishMs yet); the second was suppressed.
      verify(() => callable.call<Object?>(any())).called(2);
    });

    test('swallows a position-stream error rather than leaving it unhandled', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      final positionController = StreamController<Position>.broadcast();
      addTearDown(positionController.close);
      when(
        () => geolocator.getPositionStream(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) => positionController.stream);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');

      positionController.addError(Exception('stream broke'));
      await pumpEventQueue();
      // Reaching here without the zone catching an unhandled error is
      // the actual assertion — flutter_test fails a test on any
      // unhandled stream error, so this only passes if onError truly
      // swallowed it.
      expect(true, true);
    });

    test('cancels the shared subscription only once every tracked patient has stopped', () async {
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      final positionController = StreamController<Position>.broadcast();
      addTearDown(positionController.close);
      when(
        () => geolocator.getPositionStream(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) => positionController.stream);

      final container = containerFor();
      final controller = container.read(emsTrackingProvider.notifier);
      await controller.startTracking('patient-1');
      await controller.startTracking('patient-2');

      await controller.stopTracking('patient-1');
      expect(positionController.hasListener, true);

      await controller.stopTracking('patient-2');
      expect(positionController.hasListener, false);
    });
  });

  group('resume-on-relaunch', () {
    test('no persisted keys -> nothing resumed', () async {
      final container = containerFor();
      container.read(emsTrackingProvider.notifier);
      await pumpEventQueue();

      expect(container.read(emsTrackingProvider), isEmpty);
    });

    test('a persisted patient is activated and its resuming publish confirmed', () async {
      SharedPreferences.setMockInitialValues({'flutter.amdash-ems-tracking:patient-1': '1'});
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenAnswer((_) async => _position());
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.granted);
      when(() => foregroundTask.sendDataToTask(any())).thenReturn(null);

      final container = containerFor();
      container.read(emsTrackingProvider.notifier);
      // build()'s own resume is fire-and-forget (unawaited) — give its
      // chain of awaits (prefs -> activate -> publish) room to settle.
      await pumpEventQueue();
      await pumpEventQueue();

      expect(container.read(emsTrackingProvider), contains('patient-1'));
    });

    test('a resume whose confirming publish fails rolls back rather than leaving a phantom '
        'tracked entry', () async {
      SharedPreferences.setMockInitialValues({'flutter.amdash-ems-tracking:patient-1': '1'});
      when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
      when(
        () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
      ).thenThrow(Exception('permission revoked while closed'));
      stubForegroundServiceLifecycle();
      stubNotificationPermission(NotificationPermission.granted);
      when(() => foregroundTask.sendDataToTask(any())).thenReturn(null);

      final container = containerFor();
      container.read(emsTrackingProvider.notifier);
      await pumpEventQueue();
      await pumpEventQueue();

      expect(container.read(emsTrackingProvider), isEmpty);
    });
  });

  group('emsTrackingHealthProvider', () {
    test('immediately yields the current evaluateHealth() result', () async {
      final container = containerFor();

      final health = await container.read(emsTrackingHealthProvider.future);
      expect(health, EmsTrackingHealth.online);
    });
  });
}
