import 'dart:async';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ems_tracking_task_handler.dart';

const _updateInterval = Duration(seconds: 15);
const _storageKeyPrefix = 'amdash-ems-tracking:';

// How long after the last successful location fix tracking is still
// considered "live" before the chip falls back to "No GPS Signal". ~3x
// the publish interval, so a merely-stopped vehicle (iOS may space out
// updates when stationary) doesn't false-trip, while a genuine signal
// loss (tunnel, GPS off) still surfaces reasonably quickly. Services-off
// and permission-revoked are detected directly (and faster) below, so
// this threshold only governs the true "no fix coming through" case.
const _fixStaleThreshold = Duration(seconds: 45);

/// Why tracking isn't fully live, for the EMS-side status chip. Every cause
/// ultimately stops fixes from being published; the specific value just
/// lets the UI say *why*.
enum EmsTrackingHealth { online, locationOff, permissionDenied, noSignal }

/// Mirrors `apps/ems/src/app/services/ems-tracking.service.ts`'s public
/// API (start/stop/isTracking, localStorage-backed resume-on-relaunch),
/// with three real, platform-appropriate delivery mechanisms rather than
/// one `Timer` everywhere — a plain main-isolate `Timer` would be just as
/// vulnerable to the phone being locked as the web version's own
/// `setInterval` was, which is the whole reason this app exists:
///
/// - **Android**: a foreground-service isolate (see
///   `ems_tracking_task_handler.dart`) polling every 15s — the process
///   survives backgrounding because Android foreground services are
///   explicitly exempted from the OS's normal background-kill behavior.
/// - **iOS**: `flutter_foreground_task`'s iOS support is not adequate for
///   this — its own docs say its background task "runs for approximately
///   30 seconds every 15 minutes" (`BGTaskScheduler`, not continuous
///   execution). Apple's actual sanctioned mechanism for continuous
///   background location — exactly this app's use case — is CoreLocation's
///   own background delivery: with "Always" authorization and the
///   `location` `UIBackgroundMode` (see `ios/Runner/Info.plist`), a
///   *continuous* `Geolocator.getPositionStream()` keeps delivering
///   updates while backgrounded on its own, no foreground-service concept
///   needed. Event-driven on movement rather than a fixed 15s poll — a
///   deliberate, idiomatic difference from Android, not an oversight.
/// - **Web**: `flutter_foreground_task` has no web implementation at all
///   (foreground services are a native OS concept). Falls back to a
///   main-isolate `Timer` — the exact same ceiling the original PWA always
///   had. Running this app as a web build doesn't regress anything; it
///   just doesn't gain the background survival native gets either.
class EmsTrackingController extends Notifier<Set<String>> {
  late final FirebaseFunctions _functions;
  SharedPreferences? _prefs;
  bool _foregroundTaskInitialized = false;
  final Map<String, Timer> _webTimers = {};
  StreamSubscription<Position>? _iosPositionSubscription;

  // Wall-clock ms of the last confirmed location fix, from whichever
  // delivery path is active (iOS stream / web timer / Android isolate
  // report). Drives the "No GPS Signal" freshness fallback — see
  // [evaluateHealth].
  int? _lastFixMs;

  @override
  Set<String> build() {
    _functions = FirebaseFunctions.instanceFor(region: functionsRegion);
    // Android's tracking isolate reports its fixes back here (see
    // emsFixReportSignal); harmless no-op on other platforms, which record
    // fixes directly in-isolate.
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    ref.onDispose(() {
      for (final timer in _webTimers.values) {
        timer.cancel();
      }
      _iosPositionSubscription?.cancel();
      FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    });
    // Fire-and-forget, matching the web version's own constructor-time
    // resume — this shouldn't block the provider's own creation.
    unawaited(_resumePersisted());
    return {};
  }

  bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool isTracking(String patientId) => state.contains(patientId);

  void _recordFix() => _lastFixMs = DateTime.now().millisecondsSinceEpoch;

  void _onTaskData(Object data) {
    if (data == emsFixReportSignal) _recordFix();
  }

  bool get _isFixFresh {
    final last = _lastFixMs;
    return last != null && DateTime.now().millisecondsSinceEpoch - last < _fixStaleThreshold.inMilliseconds;
  }

  /// Current tracking health, recomputed on a cadence by
  /// [emsTrackingHealthProvider]. Checks the cheap, specific causes first
  /// (they surface faster than freshness), then falls back to fix
  /// staleness for the generic "out of service / no signal" case.
  Future<EmsTrackingHealth> evaluateHealth() async {
    // Chip shows "Offline" straight from the tracked set when nothing's
    // tracked, so health is moot then — skip the OS calls entirely.
    if (state.isEmpty) return EmsTrackingHealth.online;
    if (kIsWeb) {
      // Browsers expose neither a services toggle nor a stable permission
      // query separate from a prompt, so only freshness is meaningful.
      return _isFixFresh ? EmsTrackingHealth.online : EmsTrackingHealth.noSignal;
    }
    if (!await Geolocator.isLocationServiceEnabled()) return EmsTrackingHealth.locationOff;
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return EmsTrackingHealth.permissionDenied;
    }
    return _isFixFresh ? EmsTrackingHealth.online : EmsTrackingHealth.noSignal;
  }

  Future<void> _resumePersisted() async {
    final prefs = await _prefsInstance();
    final ids = prefs
        .getKeys()
        .where((key) => key.startsWith(_storageKeyPrefix))
        .map((key) => key.substring(_storageKeyPrefix.length))
        .toList();
    for (final id in ids) {
      await _resumeTracking(id);
    }
  }

  // Marks tracked immediately — before the confirming publish resolves —
  // matching the web version's own ordering, so a UI reading isTracking()
  // right after this service is constructed reflects "still tracking"
  // without waiting on a network round trip. Rolls back on failure (e.g.
  // location permission revoked while the app was closed).
  Future<void> _resumeTracking(String patientId) async {
    await _activate(patientId);
    try {
      await _publishCurrentPosition(patientId);
    } catch (_) {
      await _deactivate(patientId);
    }
  }

  // Deliberately does NOT short-circuit when already tracking: "already
  // tracking" only proves a *previous* publish once succeeded, not that
  // it still would now (permission could have been revoked since).
  Future<void> startTracking(String patientId) async {
    final alreadyTracking = isTracking(patientId);
    await _ensurePermissions();

    try {
      await _publishCurrentPosition(patientId);
    } catch (error) {
      await _deactivate(patientId);
      rethrow;
    }

    if (!alreadyTracking) {
      await _activate(patientId);
    }
  }

  Future<void> stopTracking(String patientId) async {
    await _deactivate(patientId);
    try {
      await _functions.httpsCallable('stopEmsLocation').call<Object?>({'patientId': patientId});
    } catch (_) {
      // Fire-and-forget, same as the web version.
    }
  }

  Future<void> _activate(String patientId) async {
    state = {...state, patientId};

    final prefs = await _prefsInstance();
    await prefs.setString('$_storageKeyPrefix$patientId', '1');

    if (kIsWeb) {
      _webTimers[patientId] = Timer.periodic(_updateInterval, (_) {
        _publishCurrentPosition(patientId).catchError((_) {});
      });
      return;
    }

    if (_isIOS) {
      _ensureIOSPositionStream();
      return;
    }

    await _ensureForegroundServiceRunning();
    FlutterForegroundTask.sendDataToTask(jsonEncode({'action': 'track', 'patientId': patientId}));
  }

  Future<void> _deactivate(String patientId) async {
    state = {...state}..remove(patientId);

    final prefs = await _prefsInstance();
    await prefs.remove('$_storageKeyPrefix$patientId');

    if (kIsWeb) {
      _webTimers.remove(patientId)?.cancel();
      return;
    }

    if (_isIOS) {
      if (state.isEmpty) {
        await _iosPositionSubscription?.cancel();
        _iosPositionSubscription = null;
      }
      return;
    }

    FlutterForegroundTask.sendDataToTask(jsonEncode({'action': 'untrack', 'patientId': patientId}));
    if (state.isEmpty) {
      await FlutterForegroundTask.stopService();
    }
  }

  // One continuous, shared stream fans out to every currently-tracked
  // patient — iOS only needs (and only reliably sustains in the
  // background) a single active CoreLocation subscription, not one per
  // patient.
  void _ensureIOSPositionStream() {
    if (_iosPositionSubscription != null) return;

    _iosPositionSubscription = Geolocator.getPositionStream(
      locationSettings: AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      ),
    ).listen(
      (position) {
        _recordFix();
        for (final patientId in state.toList()) {
          unawaited(_publishPosition(patientId, position));
        }
      },
      // A stream error (e.g. location services disabled mid-stream) just
      // means fixes stop flowing — swallow it so it doesn't go unhandled;
      // evaluateHealth surfaces the resulting staleness/cause to the chip.
      onError: (_) {},
    );
  }

  Future<void> _publishPosition(String patientId, Position position) async {
    try {
      await _functions.httpsCallable('publishEmsLocation').call<Object?>({
        'patientId': patientId,
        'latitude': position.latitude,
        'longitude': position.longitude,
      });
    } catch (_) {
      // Swallowed the same way the Android task handler's recurring
      // publishes are — a real failure surfaces via the confirming publish
      // in startTracking() instead.
    }
  }

  Future<void> _ensurePermissions() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    // "Always" (not just "when in use") is what CoreLocation requires to
    // keep delivering the stream in the background — see this class's own
    // header comment.
    if (_isIOS && permission == LocationPermission.whileInUse) {
      await Geolocator.requestPermission();
    }

    if (kIsWeb || _isIOS) return;

    final notificationPermission = await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  Future<void> _ensureForegroundServiceRunning() async {
    if (!_foregroundTaskInitialized) {
      _initForegroundTask();
      _foregroundTaskInitialized = true;
    }
    if (!await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.startService(
        serviceId: 1,
        notificationTitle: 'AmDash — EMS',
        notificationText: "Sharing this patient's live location…",
        callback: emsTrackingTaskCallback,
      );
    }
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ems_location_tracking',
        channelName: 'Live Location Tracking',
        channelDescription:
            "Shows while AmDash is sharing a patient's live location with the receiving hospital.",
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(_updateInterval.inMilliseconds),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _publishCurrentPosition(String patientId) async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 10)),
    );
    // Covers the web timer, the initial confirming publish, and resume —
    // a fix genuinely came through here.
    _recordFix();
    await _functions.httpsCallable('publishEmsLocation').call<Object?>({
      'patientId': patientId,
      'latitude': position.latitude,
      'longitude': position.longitude,
    });
  }

  Future<SharedPreferences> _prefsInstance() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }
}

final emsTrackingProvider = NotifierProvider<EmsTrackingController, Set<String>>(EmsTrackingController.new);

/// Live tracking health for the status chip.
///
/// [emsTrackingProvider] only records whether tracking was *started*, not
/// whether GPS is actually delivering — so on its own the chip would stay
/// "Tracking Online" even after location services are turned off, the
/// app's permission is revoked, or the vehicle drives out of GPS range,
/// since none of those touch the tracked set. This re-evaluates on a short
/// cadence (freshness decays with no new fixes, so it can't be purely
/// event-driven) and reports the specific cause. autoDispose so it only
/// runs while a tracking chip is actually on screen. All checks are
/// on-device — no network/API calls, no added cost.
final emsTrackingHealthProvider = StreamProvider.autoDispose<EmsTrackingHealth>((ref) async* {
  final controller = ref.read(emsTrackingProvider.notifier);
  yield await controller.evaluateHealth();
  yield* Stream<void>.periodic(const Duration(seconds: 5)).asyncMap((_) => controller.evaluateHealth());
});
