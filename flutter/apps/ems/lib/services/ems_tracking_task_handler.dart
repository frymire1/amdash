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
  DateTime? _lastAmbulancePublishAt;

  FirebaseFunctions get _functionsInstance =>
      _functions ??= _functionsOverride ?? FirebaseFunctions.instanceFor(region: functionsRegion); // coverage:ignore-line

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

    final Position position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (error) {
      // Same tolerance as the web version: a revoked/unavailable permission
      // just means this cycle's publish is skipped, not a crash. Also means
      // no fix is reported back, so the main isolate's freshness clock goes
      // stale and the chip falls back to "No GPS Signal" — the intended
      // behavior when GPS drops mid-transport. Logged, not just silently
      // swallowed — confirmed for real this silence cost real debugging
      // time once already (a genuine failure here was indistinguishable
      // from the service simply not running at all).
      debugPrint('EmsTrackingTaskHandler._publishAllTracked: getCurrentPosition failed: $error');
      return;
    }

    // A fix genuinely came through — let the main isolate know so its
    // status chip stays "live" (see EmsTrackingController._onTaskData).
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
      case 'clearAmbulanceId':
        _ambulanceId = null;
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _trackedPatientIds.clear();
    _ambulanceId = null;
    _lastAmbulancePublishAt = null;
  }
}
