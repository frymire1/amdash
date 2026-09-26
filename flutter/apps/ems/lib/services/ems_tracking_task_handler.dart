import 'dart:async';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

import '../firebase_options.dart';

const functionsRegion = 'northamerica-northeast2';

/// Marker this isolate sends back to the main isolate (over
/// sendDataToMain) on each successful location fix, so the main isolate's
/// EmsTrackingController can keep its freshness clock current even though
/// the fixes happen over here in a separate process. Consumed by
/// EmsTrackingController._onTaskData.
const emsFixReportSignal = 'ems-fix';

// How often an identified-but-idle ambulance publishes its own location —
// see EmsTrackingController's own identical constant (ems_tracking_service
// .dart) for the full "why 4x the 15s tick" reasoning; kept as a separate
// constant here (not shared) since this file runs in a genuinely separate
// isolate with no shared Dart state.
const _idleAmbulancePublishInterval = Duration(seconds: 60);

/// Must be a top-level (or static) function — this is what
/// `FlutterForegroundTask.startService(callback: ...)` runs to install the
/// handler in the dedicated background isolate the foreground service
/// keeps alive. Never called directly by a test — it's the real isolate
/// entry point, only ever invoked by the OS/plugin at real runtime (same
/// exclusion category TESTING.md already gives main.dart): constructing
/// `EmsTrackingTaskHandler()` itself no longer throws (see its own
/// constructor comment on why that used to happen for real, not just in
/// tests), but `FlutterForegroundTask.setTaskHandler(...)` still needs a
/// real plugin/isolate context a plain VM test doesn't have.
// coverage:ignore-start
@pragma('vm:entry-point')
void emsTrackingTaskCallback() {
  FlutterForegroundTask.setTaskHandler(EmsTrackingTaskHandler());
}
// coverage:ignore-end

/// Runs in its own isolate, kept alive by Android's foreground-service
/// mechanism — this, not a main-isolate `Timer`, is what actually
/// survives the phone being locked mid-transport (the entire reason this
/// app moved off the web PWA — see `ems-tracking.service.ts`'s equivalent,
/// web `setInterval`, which browsers throttle or suspend once the tab is
/// genuinely backgrounded). Tracked patient IDs are pushed in from the
/// main isolate via `sendDataToTask` (see `EmsTrackingController`) rather
/// than read from shared Dart state, since a foreground-service isolate on
/// Android is a fully separate process-level isolate with no shared heap.
class EmsTrackingTaskHandler extends TaskHandler {
  // Both params exist purely as testability seams — this class is
  // instantiated by the plugin itself via emsTrackingTaskCallback()
  // above, not through Riverpod, so there's no ref to route through
  // instead. The real call site is unchanged: still just
  // `EmsTrackingTaskHandler()`. [firebaseReady] lets a test skip past
  // _ensureFirebase()'s real Firebase.initializeApp call (genuine
  // isolate-bootstrap glue, see that method's own comment) so that
  // everything *downstream* of it — onStart, and nearly all of
  // _publishAllTracked — stays testable; without this, the very first
  // line either method reaches would throw in a plain VM test (no
  // platform channel for Firebase.initializeApp to complete against),
  // making almost this entire class untestable over one bootstrap call.
  //
  // [functions] is deliberately NOT resolved to its real
  // FirebaseFunctions.instanceFor(...) fallback here in the constructor
  // — confirmed for real via a genuine Firebase Test Lab failure (not
  // just a test-only concern): this constructor's own initializer list
  // runs synchronously the instant the plugin calls
  // `FlutterForegroundTask.setTaskHandler(EmsTrackingTaskHandler())` in
  // emsTrackingTaskCallback, which is BEFORE onStart — and thus
  // _ensureFirebase's real Firebase.initializeApp call — ever runs in
  // this isolate. Eagerly constructing FirebaseFunctions.instanceFor(...)
  // right here crashed every real invocation with
  // "[core/no-app] No Firebase App '[DEFAULT]' has been created" — this
  // isolate has no Firebase app yet at construction time, only once
  // onStart/_ensureFirebase has actually run. Resolved lazily instead via
  // [_functionsInstance], the first time _publishAllTracked actually
  // needs it — by then _ensureFirebase has already completed. The `??`
  // fallback itself is still never exercised by a test, same reasoning
  // as DirectionsService's twin fallback (see that file's own comment) —
  // every test here supplies [functions] directly.
  EmsTrackingTaskHandler({FirebaseFunctions? functions, @visibleForTesting bool firebaseReady = false})
    : _functionsOverride = functions,
      // Not `this._firebaseReady` — an initializing formal takes the
      // field's own (private) name, which a test in a different library
      // could never pass by name at all.
      // ignore: prefer_initializing_formals
      _firebaseReady = firebaseReady;

  final FirebaseFunctions? _functionsOverride;
  FirebaseFunctions? _functions;
  final Set<String> _trackedPatientIds = {};
  bool _firebaseReady;
  String? _ambulanceId;
  String? _phoneNumber;
  DateTime? _lastAmbulancePublishAt;

  // The most recent fix from the persistent stream below — read directly
  // by _publishAllTracked instead of a fresh per-tick request. See
  // _ensurePositionStream's own doc comment for why a one-shot request
  // per tick doesn't work here.
  Position? _lastPosition;
  StreamSubscription<Position>? _positionSubscription;

  FirebaseFunctions get _functionsInstance =>
      _functions ??= _functionsOverride ?? FirebaseFunctions.instanceFor(region: functionsRegion); // coverage:ignore-line

  /// A single, long-lived position stream for this isolate's entire
  /// lifetime, rather than a fresh `Geolocator.getCurrentPosition()`
  /// one-shot request on every 15s tick (the original design). Confirmed
  /// via a real Firebase Test Lab run's full logcat (not just its own
  /// debugPrint output — the raw GCS logcat, since the CI step's own
  /// filtered dump truncates at 20000 bytes) that switching this isolate
  /// truly backgrounded broke `getCurrentPosition()` outright: the
  /// device's real GNSS hardware kept delivering fixes at the native layer
  /// throughout (`Gnss:onGnssLocationCb` firing roughly once a second, the
  /// whole 40s window), yet `getCurrentPosition()` — called fresh on three
  /// separate ticks, each with its own 10s `timeLimit` — never resolved
  /// *or* rejected even once; no fix was ever recorded, and no timeout
  /// error was ever logged either. A one-shot request appears not to bind
  /// reliably to this isolate's own location-provider client once the
  /// host Activity is genuinely backgrounded, even though the isolate
  /// itself (kept alive by the foreground-service exemption) is still
  /// very much running. A persistent stream, established once in
  /// [onStart] rather than re-requested every tick, is the same mechanism
  /// this app's own iOS path already uses successfully
  /// (`EmsTrackingController._ensureIOSPositionStream`,
  /// ems_tracking_service.dart) — each tick here just reads whatever
  /// [_lastPosition] the stream has already delivered, rather than
  /// blocking on a fresh request of its own.
  void _ensurePositionStream() {
    if (_positionSubscription != null) return;
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0),
    ).listen(
      (position) => _lastPosition = position,
      // A stream error just means fixes stop updating — the next tick's
      // own "no position yet" branch in _publishAllTracked is what
      // surfaces that (via debugLastFixAtMs going stale on the main
      // isolate side), not a crash here.
      onError: (Object error) => debugPrint('EmsTrackingTaskHandler: position stream error: $error'),
    );
  }

  // Firebase.initializeApp is genuine isolate-bootstrap glue — same
  // category TESTING.md already excludes main.dart's own call for
  // (covered by e2e running the real isolate instead). Nothing to fake
  // it with here either: unlike Firestore/Auth/Functions, there's no
  // overridable seam for "is Firebase already initialized in this
  // isolate" that a unit test could substitute a fake for — hence
  // [firebaseReady] above, letting a test skip this method's body
  // entirely rather than the method itself becoming untestable.
  Future<void> _ensureFirebase() async {
    if (_firebaseReady) return;
    // coverage:ignore-start
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    _firebaseReady = true;
    // coverage:ignore-end
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _ensureFirebase();
    _ensurePositionStream();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Confirms this isolate's own recurring timer is genuinely still
    // ticking at all — the one signal none of the try/catch blocks below
    // could ever surface on their own, since a service that silently
    // stopped being scheduled by the OS wouldn't reach any of them either.
    debugPrint(
      'EmsTrackingTaskHandler.onRepeatEvent: tracking ${_trackedPatientIds.length} patient(s), '
      'ambulance ${_ambulanceId ?? "none"}',
    );
    _publishAllTracked(timestamp);
  }

  Future<void> _publishAllTracked(DateTime timestamp) async {
    final isTransporting = _trackedPatientIds.isNotEmpty;
    // Due immediately while actively transporting — piggybacks the
    // existing per-patient tick below rather than a separate timer (see
    // EmsTrackingController._syncAmbulanceTracking's own doc comment on
    // why). Otherwise due once _idleAmbulancePublishInterval has actually
    // elapsed since the last ambulance-specific publish — this is a
    // genuinely separate cadence from the per-patient one below, which
    // this method still runs every 15s regardless (it just skips the
    // ambulance publish on ticks that aren't due yet).
    final ambulanceDue =
        _ambulanceId != null &&
        (isTransporting ||
            _lastAmbulancePublishAt == null ||
            timestamp.difference(_lastAmbulancePublishAt!) >= _idleAmbulancePublishInterval);

    if (_trackedPatientIds.isEmpty && !ambulanceDue) return;
    await _ensureFirebase();
    // Real device/isolate-context bootstrapping — see this getter's own
    // constructor-comment reasoning for why _ensureFirebase runs first,
    // same idea here: the stream is idempotently (re-)ensured on every
    // tick in case onStart's own call somehow hasn't landed yet by the
    // very first tick, though in practice it always has by then.
    _ensurePositionStream();

    final position = _lastPosition;
    if (position == null) {
      // No fix delivered yet — same tolerance as the old one-shot
      // request's own failure path: this cycle's publish is skipped, not
      // a crash, and no fix is reported back, so the main isolate's
      // freshness clock goes stale and the chip falls back to "No GPS
      // Signal". Logged for the same visibility reason the one-shot
      // version's own catch block was.
      debugPrint('EmsTrackingTaskHandler._publishAllTracked: no position fix yet');
      return;
    }

    // A fix genuinely came through — let the main isolate know so its
    // status chip stays "live" (see EmsTrackingController._onTaskData).
    // Reaching the main isolate at all depends on
    // FlutterForegroundTask.initCommunicationPort() having been called on
    // that side (main.dart's own real bootstrap does; a Patrol test has
    // to call it too, since it constructs EmsApp() directly rather than
    // going through main() — see background_gps_tracking_test.dart's own
    // doc comment for the real failure chasing this down without that
    // context cost, before finding it).
    FlutterForegroundTask.sendDataToMain(emsFixReportSignal);

    for (final patientId in _trackedPatientIds.toList()) {
      try {
        await _functionsInstance.httpsCallable('publishEmsLocation').call<Object?>({
          'patientId': patientId,
          'latitude': position.latitude,
          'longitude': position.longitude,
        });
      } catch (error) {
        // Swallowed the same way the web interval's recurring publishes
        // are — the main isolate's own confirming publish (see
        // EmsTrackingController.startTracking) is what surfaces a real
        // failure to the UI; this loop just tries again next cycle.
        // Logged for the same visibility reason as the Geolocator catch
        // above.
        debugPrint('EmsTrackingTaskHandler._publishAllTracked: publishEmsLocation failed for $patientId: $error');
      }
    }

    if (ambulanceDue) {
      _lastAmbulancePublishAt = timestamp;
      try {
        await _functionsInstance.httpsCallable('publishAmbulanceLocation').call<Object?>({
          'ambulanceId': _ambulanceId,
          'phoneNumber': _phoneNumber,
          'latitude': position.latitude,
          'longitude': position.longitude,
          'isTransporting': isTransporting,
        });
      } catch (error) {
        // Same visibility/tolerance reasoning as the per-patient catch
        // above.
        debugPrint('EmsTrackingTaskHandler._publishAllTracked: publishAmbulanceLocation failed: $error');
      }
    }
  }

  @override
  void onReceiveData(Object data) {
    if (data is! String) return;
    final decoded = jsonDecode(data) as Map<String, Object?>;

    // Per-case null checks, not one blanket early return on a missing
    // patientId (the shape the track/untrack cases used to share) —
    // setAmbulanceId/clearAmbulanceId messages never carry a patientId at
    // all, so a blanket check would have silently dropped them too.
    switch (decoded['action']) {
      case 'track':
        final patientId = decoded['patientId'] as String?;
        if (patientId != null) _trackedPatientIds.add(patientId);
      case 'untrack':
        final patientId = decoded['patientId'] as String?;
        if (patientId != null) _trackedPatientIds.remove(patientId);
      case 'setAmbulanceId':
        _ambulanceId = decoded['ambulanceId'] as String?;
        _phoneNumber = decoded['phoneNumber'] as String?;
      case 'clearAmbulanceId':
        _ambulanceId = null;
        _phoneNumber = null;
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _trackedPatientIds.clear();
    _ambulanceId = null;
    _phoneNumber = null;
    _lastAmbulancePublishAt = null;
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _lastPosition = null;
  }
}
