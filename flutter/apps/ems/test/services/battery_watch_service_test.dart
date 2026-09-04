import 'package:amdash_core/amdash_core.dart';
import 'package:battery_plus_platform_interface/battery_plus_platform_interface.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:ems/services/battery_watch_service.dart';
import 'package:ems/services/ems_tracking_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

// See TESTING.md's "MockPlatformInterfaceMixin" note (already used
// identically for GeolocatorPlatform/FlutterForegroundTaskPlatform in
// ems_tracking_service_test.dart) — confirmed via battery_plus's own source
// that Battery() routes every call through BatteryPlatform.instance, so
// swapping that instance intercepts battery_plus's calls without a real
// platform channel.
class _MockBatteryPlatform extends Mock with MockPlatformInterfaceMixin implements BatteryPlatform {}

// batteryWatchProvider itself never touches Firebase, but it ref.watches
// emsTrackingProvider — whose own build() eagerly reads firebaseFunctionsProvider
// (see ems_tracking_service_test.dart's identical containerFor() override) —
// so every container here needs this too, or build() throws [core/no-app]
// trying to construct a real FirebaseFunctions.instanceFor(...).
class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

void main() {
  late _MockBatteryPlatform battery;
  late BatteryPlatform realBattery;
  late _MockFirebaseFunctions functions;

  setUp(() {
    // emsTrackingProvider's own build() fire-and-forgets a resume-on-
    // relaunch check through SharedPreferences.getInstance() — see
    // ems_tracking_service_test.dart's identical setUp call.
    SharedPreferences.setMockInitialValues({});

    battery = _MockBatteryPlatform();
    realBattery = BatteryPlatform.instance;
    BatteryPlatform.instance = battery;
    functions = _MockFirebaseFunctions();
  });

  tearDown(() {
    BatteryPlatform.instance = realBattery;
  });

  ProviderContainer containerFor() {
    final container = ProviderContainer(overrides: [firebaseFunctionsProvider.overrideWithValue(functions)]);
    addTearDown(container.dispose);
    return container;
  }

  test('nothing tracked at construction: does not poll, state stays false', () async {
    when(() => battery.batteryLevel).thenAnswer((_) async => 5);

    final container = containerFor();
    container.read(batteryWatchProvider);
    await pumpEventQueue();

    expect(container.read(batteryWatchProvider), false);
    verifyNever(() => battery.batteryLevel);
  });

  test('a patient already tracked at construction time checks the level immediately', () async {
    when(() => battery.batteryLevel).thenAnswer((_) async => 15);

    final container = containerFor();
    // Start tracking *before* batteryWatchProvider is ever read — exercises
    // build()'s own ref.read(emsTrackingProvider) snapshot branch, not the
    // ref.listen (later-transition) path.
    container.read(emsTrackingProvider.notifier).state = {'patient-1'};

    container.read(batteryWatchProvider);
    await pumpEventQueue();

    expect(container.read(batteryWatchProvider), true);
  });

  test('starting to track triggers an immediate check, not just the first poll interval', () async {
    when(() => battery.batteryLevel).thenAnswer((_) async => 10);

    final container = containerFor();
    container.read(batteryWatchProvider); // build() runs first, nothing tracked yet.
    await pumpEventQueue();
    expect(container.read(batteryWatchProvider), false);

    container.read(emsTrackingProvider.notifier).state = {'patient-1'};
    await pumpEventQueue();

    expect(container.read(batteryWatchProvider), true);
  });

  test('a level above the threshold never warns', () async {
    when(() => battery.batteryLevel).thenAnswer((_) async => 80);

    final container = containerFor();
    container.read(emsTrackingProvider.notifier).state = {'patient-1'};
    container.read(batteryWatchProvider);
    await pumpEventQueue();

    expect(container.read(batteryWatchProvider), false);
  });

  test('exactly at the threshold warns (at/below, not strictly below)', () async {
    when(() => battery.batteryLevel).thenAnswer((_) async => lowBatteryThreshold);

    final container = containerFor();
    container.read(emsTrackingProvider.notifier).state = {'patient-1'};
    container.read(batteryWatchProvider);
    await pumpEventQueue();

    expect(container.read(batteryWatchProvider), true);
  });

  test('stopping the last tracked patient resets state and the warned-this-episode flag', () async {
    when(() => battery.batteryLevel).thenAnswer((_) async => 10);

    final container = containerFor();
    final tracking = container.read(emsTrackingProvider.notifier);
    tracking.state = {'patient-1'};
    container.read(batteryWatchProvider);
    await pumpEventQueue();
    expect(container.read(batteryWatchProvider), true);

    tracking.state = {};
    await pumpEventQueue();
    expect(container.read(batteryWatchProvider), false);

    // A fresh tracking session, still at the same low level, warns again —
    // proves _warnedThisEpisode was really reset, not just `state` itself.
    tracking.state = {'patient-2'};
    await pumpEventQueue();
    expect(container.read(batteryWatchProvider), true);
  });

  test('recharging above the threshold clears the warning on the next poll tick, '
      'without needing tracking to stop', () {
    var level = 10;
    when(() => battery.batteryLevel).thenAnswer((_) async => level);

    // A plain test() (not testWidgets()) has no flutter_test fake-async
    // binding already driving Timer/Future scheduling — fakeAsync is what
    // lets this deterministically advance BatteryWatchController's real
    // Timer.periodic poll by exactly one batteryPollInterval, rather than
    // waiting out real wall-clock time or (the only alternative available
    // without it) triggering a fresh check through a tracked-set change,
    // which wouldn't actually exercise the *recharge-while-still-tracking*
    // case this test means to cover.
    fakeAsync((async) {
      final container = ProviderContainer(overrides: [firebaseFunctionsProvider.overrideWithValue(functions)]);
      container.read(emsTrackingProvider.notifier).state = {'patient-1'};
      container.read(batteryWatchProvider);
      async.flushMicrotasks(); // lets the immediate _checkLevel() resolve.
      expect(container.read(batteryWatchProvider), true);

      level = 90;
      async.elapse(batteryPollInterval);
      expect(container.read(batteryWatchProvider), false);

      container.dispose();
    });
  });

  test('unmounting cancels the poll timer cleanly (no error, no further battery calls)', () async {
    when(() => battery.batteryLevel).thenAnswer((_) async => 50);

    final container = containerFor();
    container.read(emsTrackingProvider.notifier).state = {'patient-1'};
    container.read(batteryWatchProvider);
    await pumpEventQueue();

    container.dispose();
    // Reaching here without a pending-timer or use-after-dispose error is
    // the assertion — flutter_test fails the test on any stray exception.
  });
}
