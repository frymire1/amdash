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

  @override
  Set<String> build() {
    _functions = FirebaseFunctions.instanceFor(region: functionsRegion);
    ref.onDispose(() {
      for (final timer in _webTimers.values) {
        timer.cancel();
      }
      _iosPositionSubscription?.cancel();
    });
    // Fire-and-forget, matching the web version's own constructor-time
    // resume — this shouldn't block the provider's own creation.
    unawaited(_resumePersisted());
    return {};
  }

  bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool isTracking(String patientId) => state.contains(patientId);

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
    ).listen((position) {
      for (final patientId in state.toList()) {
        unawaited(_publishPosition(patientId, position));
      }
    });
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
