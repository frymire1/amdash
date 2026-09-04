import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ems_tracking_service.dart';

/// Battery percentage at/below which EMS should be warned tracking may
/// stop working soon. 20%, not 0% or 5% — the point is real time left to
/// plug in or hand off before the device actually dies mid-transport, not
/// a warning that arrives too late to act on.
const lowBatteryThreshold = 20;

/// How often to poll the battery level while actively tracking at least
/// one patient. battery_plus exposes no level-*change* stream — only a
/// charging-*state* stream (`onBatteryStateChanged`) — so polling is the
/// only way to notice a level that's merely drained, not one whose
/// charging state changed.
const batteryPollInterval = Duration(minutes: 2);

/// Purely client-side, purely preventive — the battery level only ever
/// existed on-device, so there's no reason to round-trip it through the
/// server the way EMS's connectivity-loss alerts do (see
/// `functions/src/ems.ts`'s `checkEmsConnectivity` for that server-side,
/// after-the-fact detection; this is meant to help EMS avoid ever reaching
/// that state in the first place). No FCM, no Cloud Function involved at
/// all.
///
/// `state` is just "should `BatteryWarningBanner` show right now" — true
/// once battery drops to/below [lowBatteryThreshold] while tracking is
/// active, and stays true (a persistent warning, not a toast) until either
/// the level recovers above the threshold (presumably plugged in) or the
/// last tracked patient is removed. A *fresh* tracking session starting
/// later can warn again even if the level never recovered — the reset
/// happens on either condition, not just recharging.
///
/// Deliberately doesn't `ref.watch(emsTrackingProvider)` inside [build] —
/// TESTING.md's own documented Notifier pitfall (a `state = ...`
/// assignment made *during* a synchronous `build()` call gets silently
/// discarded, overwritten by whatever `build()` itself later returns) is
/// exactly the shape a `fireImmediately: true` listener registered inside
/// `build()` would create here. Instead, [build] takes one plain
/// `ref.read` snapshot to decide whether to start polling immediately
/// (covers the case this provider is first read while a patient is
/// already being tracked — e.g. a hot-restart, or resume-on-relaunch
/// having already run), and a plain `ref.listen` (no `fireImmediately`)
/// handles every *later* transition safely outside `build()`.
class BatteryWatchController extends Notifier<bool> {
  Timer? _pollTimer;
  bool _warnedThisEpisode = false;
  final Battery _battery = Battery();

  @override
  bool build() {
    ref.onDispose(_stopPolling);
    ref.listen<Set<String>>(emsTrackingProvider, (previous, next) => _onTrackedSetChanged(next));

    if (ref.read(emsTrackingProvider).isNotEmpty) {
      _startPolling();
    }
    return false; // nothing has been checked yet at construction time.
  }

  void _onTrackedSetChanged(Set<String> tracked) {
    if (tracked.isEmpty) {
      _stopPolling();
      _warnedThisEpisode = false;
      state = false;
      return;
    }
    _startPolling();
  }

  void _startPolling() {
    if (_pollTimer != null) return; // already polling for this session.
    _pollTimer = Timer.periodic(batteryPollInterval, (_) => unawaited(_checkLevel()));
    // Don't wait a full batteryPollInterval for the very first check — a
    // patient tracked with an already-low battery should warn promptly.
    unawaited(_checkLevel());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _checkLevel() async {
    final level = await _battery.batteryLevel;
    if (level <= lowBatteryThreshold) {
      if (!_warnedThisEpisode) {
        _warnedThisEpisode = true;
        state = true;
      }
    } else if (state) {
      // Recharged back above the threshold — a future dip should be able
      // to warn again.
      _warnedThisEpisode = false;
      state = false;
    }
  }
}

final batteryWatchProvider = NotifierProvider<BatteryWatchController, bool>(BatteryWatchController.new);
