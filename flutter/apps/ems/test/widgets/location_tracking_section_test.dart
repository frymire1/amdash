import 'dart:async';

import 'package:ems/services/ems_tracking_service.dart';
import 'package:ems/widgets/location_tracking_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:mocktail/mocktail.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../support/pump_app.dart';

// See ems_tracking_service_test.dart's identical note — confirmed for real
// that swapping GeolocatorPlatform.instance intercepts the plugin's static
// calls in a plain `flutter test` run.
class _MockGeolocatorPlatform extends Mock with MockPlatformInterfaceMixin implements GeolocatorPlatform {}

// A minimal fake for emsTrackingProvider — LocationTrackingSection only
// ever reads .isTracking(patientId) off it (a plain state.contains check),
// so there's no need to replicate EmsTrackingController's real Firebase/
// foreground-task machinery here.
class _FakeEmsTrackingController extends EmsTrackingController {
  _FakeEmsTrackingController(this._initial);
  final Set<String> _initial;

  @override
  Set<String> build() => _initial;
}

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
  });

  late _MockGeolocatorPlatform geolocator;
  late GeolocatorPlatform realGeolocator;

  setUp(() {
    geolocator = _MockGeolocatorPlatform();
    realGeolocator = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = geolocator;
  });

  tearDown(() {
    GeolocatorPlatform.instance = realGeolocator;
  });

  Future<void> pumpSection(
    WidgetTester tester, {
    String? patientId,
    ValueChanged<LocationTrackingValue>? onChanged,
    Set<String> trackedPatients = const {},
  }) {
    return pumpApp(
      tester,
      LocationTrackingSection(patientId: patientId, onChanged: onChanged ?? (_) {}),
      overrides: [emsTrackingProvider.overrideWith(() => _FakeEmsTrackingController(trackedPatients))],
    );
  }

  testWidgets('permission denied requests it, then proceeds once granted', (tester) async {
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.denied);
    when(() => geolocator.requestPermission()).thenAnswer((_) async => LocationPermission.always);
    when(
      () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
    ).thenAnswer((_) async => _position());

    await pumpSection(tester);
    await tester.pumpAndSettle();

    verify(() => geolocator.requestPermission()).called(1);
    expect(find.text('Tracking Active'), findsOneWidget);
  });

  testWidgets('a successful fetch shows Tracking Active and reports lat/lng via onChanged', (tester) async {
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
    when(
      () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
    ).thenAnswer((_) async => _position(latitude: 45.42, longitude: -75.69));

    LocationTrackingValue? reported;
    await pumpSection(tester, onChanged: (v) => reported = v);
    await tester.pumpAndSettle();

    expect(find.text('Tracking Active'), findsOneWidget);
    expect(reported?.latitude, 45.42);
    expect(reported?.longitude, -75.69);
    expect(reported?.liveTrackingEnabled, true);
    expect(reported?.hasLocationError, false);
  });

  testWidgets('a Geolocator failure shows the error, force-disables tracking, and reports hasLocationError', (
    tester,
  ) async {
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
    when(
      () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
    ).thenThrow(Exception('location services disabled'));

    LocationTrackingValue? reported;
    await pumpSection(tester, onChanged: (v) => reported = v);
    await tester.pumpAndSettle();

    expect(
      find.text('Could not get your current location. Please allow location access and try again.'),
      findsOneWidget,
    );
    expect(reported?.hasLocationError, true);
    expect(reported?.liveTrackingEnabled, false);

    // Disabled (not just off) while _locationError != null.
    final switchTile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(switchTile.onChanged, isNull);
  });

  testWidgets('the real 12s fetch timeout also surfaces as the same location error', (tester) async {
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
    // A Completer that's simply never completed, not Future.delayed — the
    // latter leaves a real, still-pending Timer behind (Future.timeout()
    // only races a second Future against the original; it doesn't cancel
    // whatever the original was actually doing), which flutter_test's
    // binding flags as a leaked timer at teardown. A Completer's Future
    // has no Timer of its own, so there's nothing left to leak once
    // Geolocator.getCurrentPosition(...).timeout(12s)'s own real Dart-level
    // timeout in the source ends this — which is exactly what this test
    // wants to exercise.
    when(
      () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
    ).thenAnswer((_) => Completer<Position>().future);

    await pumpSection(tester);
    await tester.pump(const Duration(seconds: 13));
    await tester.pump();

    expect(
      find.text('Could not get your current location. Please allow location access and try again.'),
      findsOneWidget,
    );
  });

  testWidgets('the 15s periodic poll re-fetches automatically', (tester) async {
    var calls = 0;
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
    when(() => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings'))).thenAnswer((
      _,
    ) async {
      calls++;
      return _position();
    });

    await pumpSection(tester);
    await tester.pumpAndSettle();
    expect(calls, 1);

    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(calls, 2);

    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(calls, 3);
  });

  testWidgets('an in-flight fetch guards against an overlapping poll tick', (tester) async {
    // The realistic overlap this guards against isn't two
    // getCurrentPosition() calls racing each other — that's capped at 12s
    // by the source's own .timeout(), safely under the 15s poll interval,
    // so it can never still be in flight when the next tick fires.
    // requestPermission() has no such timeout at all, though (it awaits
    // the OS's native permission prompt, which a user can leave open
    // indefinitely) — confirmed via bisection (a source-level print
    // showing _isFetchingLocation was already back to false by t=15s in
    // an earlier, wrong version of this test that stalled
    // getCurrentPosition() instead) that *that's* the realistic slow step
    // the guard has to survive a poll tick landing on top of.
    var permissionCalls = 0;
    final requestPermission = Completer<LocationPermission>();
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.denied);
    when(() => geolocator.requestPermission()).thenAnswer((_) {
      permissionCalls++;
      return permissionCalls == 1 ? requestPermission.future : Future.value(LocationPermission.always);
    });
    when(
      () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
    ).thenAnswer((_) async => _position());

    await pumpSection(tester);
    // Past the periodic timer's 15s interval, but the permission prompt
    // from initState's own fetch is still unanswered — the guard
    // (_isFetchingLocation) should suppress the overlapping call this tick
    // would otherwise make.
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(permissionCalls, 1);

    // Let the (simulated) permission prompt resolve, clearing
    // _isFetchingLocation...
    requestPermission.complete(LocationPermission.always);
    await tester.pump();
    await tester.pump();

    // ...then the *next* periodic tick (t=30s from the timer's own
    // creation) can fetch again for real.
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(permissionCalls, 2);
  });

  testWidgets('an in-flight fetch also guards against an overlapping Retry tap', (tester) async {
    var calls = 0;
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
    when(() => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings'))).thenAnswer((
      _,
    ) async {
      calls++;
      await Future<void>.delayed(const Duration(seconds: 5));
      return _position();
    });

    await pumpSection(tester);
    await tester.pump(const Duration(seconds: 1));
    // Still fetching — Retry should be disabled, not just tappable-and-
    // ignored, but tap it anyway to confirm onPressed is genuinely null.
    final retryButton = tester.widget<TextButton>(find.byType(TextButton));
    expect(retryButton.onPressed, isNull);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('app resuming triggers an immediate re-fetch', (tester) async {
    var calls = 0;
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
    when(() => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings'))).thenAnswer((
      _,
    ) async {
      calls++;
      return _position();
    });

    await pumpSection(tester);
    await tester.pumpAndSettle();
    expect(calls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('create mode (no patientId) defaults live tracking on', (tester) async {
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
    when(
      () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
    ).thenAnswer((_) async => _position());

    LocationTrackingValue? reported;
    await pumpSection(tester, onChanged: (v) => reported = v);
    await tester.pumpAndSettle();

    expect(reported?.liveTrackingEnabled, true);
  });

  testWidgets('edit mode seeds live tracking from emsTrackingProvider.isTracking(patientId)', (tester) async {
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
    when(
      () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
    ).thenAnswer((_) async => _position());

    LocationTrackingValue? reported;
    await pumpSection(
      tester,
      patientId: 'other-patient',
      onChanged: (v) => reported = v,
      trackedPatients: const {'some-other-patient'},
    );
    // The very first _reportChange() (before the fetch even resolves)
    // already reflects the seeded, not-tracked value.
    expect(reported?.liveTrackingEnabled, false);
  });

  testWidgets('edit mode seeded as already tracking starts with the switch on', (tester) async {
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
    when(
      () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
    ).thenAnswer((_) async => _position());

    LocationTrackingValue? reported;
    await pumpSection(
      tester,
      patientId: 'patient-1',
      onChanged: (v) => reported = v,
      trackedPatients: const {'patient-1'},
    );
    expect(reported?.liveTrackingEnabled, true);
  });

  testWidgets('toggling the switch off reports the change', (tester) async {
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
    when(
      () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
    ).thenAnswer((_) async => _position());

    LocationTrackingValue? reported;
    await pumpSection(tester, onChanged: (v) => reported = v);
    await tester.pumpAndSettle();
    expect(reported?.liveTrackingEnabled, true);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();

    expect(reported?.liveTrackingEnabled, false);
  });

  testWidgets('unmounting disposes cleanly (observer removed, poll timer cancelled)', (tester) async {
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
    when(
      () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
    ).thenAnswer((_) async => _position());

    await pumpSection(tester);
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);

    // If the poll timer or lifecycle observer were still live, this would
    // throw (using a disposed State/context) rather than pass quietly.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 20));
    expect(tester.takeException(), isNull);
  });
}
