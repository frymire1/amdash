import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

import '../firebase_options.dart';

const functionsRegion = 'northamerica-northeast2';

/// Must be a top-level (or static) function — this is what
/// `FlutterForegroundTask.startService(callback: ...)` runs to install the
/// handler in the dedicated background isolate the foreground service
/// keeps alive.
@pragma('vm:entry-point')
void emsTrackingTaskCallback() {
  FlutterForegroundTask.setTaskHandler(EmsTrackingTaskHandler());
}

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
  final Set<String> _trackedPatientIds = {};
  bool _firebaseReady = false;

  Future<void> _ensureFirebase() async {
    if (_firebaseReady) return;
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    _firebaseReady = true;
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _ensureFirebase();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _publishAllTracked();
  }

  Future<void> _publishAllTracked() async {
    if (_trackedPatientIds.isEmpty) return;
    await _ensureFirebase();

    final Position position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (_) {
      // Same tolerance as the web version: a revoked/unavailable permission
      // just means this cycle's publish is skipped, not a crash.
      return;
    }

    final functions = FirebaseFunctions.instanceFor(region: functionsRegion);
    for (final patientId in _trackedPatientIds.toList()) {
      try {
        await functions.httpsCallable('publishEmsLocation').call<Object?>({
          'patientId': patientId,
          'latitude': position.latitude,
          'longitude': position.longitude,
        });
      } catch (_) {
        // Swallowed the same way the web interval's recurring publishes
        // are — the main isolate's own confirming publish (see
        // EmsTrackingController.startTracking) is what surfaces a real
        // failure to the UI; this loop just tries again next cycle.
      }
    }
  }

  @override
  void onReceiveData(Object data) {
    if (data is! String) return;
    final decoded = jsonDecode(data) as Map<String, Object?>;
    final patientId = decoded['patientId'] as String?;
    if (patientId == null) return;

    switch (decoded['action']) {
      case 'track':
        _trackedPatientIds.add(patientId);
      case 'untrack':
        _trackedPatientIds.remove(patientId);
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _trackedPatientIds.clear();
  }
}
