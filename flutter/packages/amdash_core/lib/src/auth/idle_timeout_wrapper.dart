import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_service.dart';

/// HIPAA's Security Rule lists "Automatic Logoff" as an addressable Access
/// Control specification (45 CFR §164.312(a)(2)(iii)) — the rule itself
/// sets no fixed number, just a "risk-based inactivity period." 15 minutes
/// is used uniformly across all three apps here, rather than justifying a
/// different number per app.
const idleTimeoutDuration = Duration(minutes: 15);

/// Signs the user out after [idleTimeoutDuration] of no pointer/keyboard
/// activity — a workstation or device left unattended while still signed
/// in is a real PHI exposure. Wrapped around the whole app (via
/// `MaterialApp.router`'s `builder`) rather than only the authenticated
/// routes — signing out an already-signed-out session is a harmless no-op,
/// simpler than threading this through every app's route structure.
///
/// Tracks a real `_lastActivity` timestamp rather than trusting a single
/// `Timer` to fire exactly on schedule — a backgrounded mobile app can have
/// its timers suspended/delayed by the OS, so `didChangeAppLifecycleState`
/// re-checks elapsed idle time immediately on resume instead of waiting for
/// whatever's left of a possibly-stale timer.
class IdleTimeoutWrapper extends ConsumerStatefulWidget {
  const IdleTimeoutWrapper({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<IdleTimeoutWrapper> createState() => _IdleTimeoutWrapperState();
}

class _IdleTimeoutWrapperState extends ConsumerState<IdleTimeoutWrapper> with WidgetsBindingObserver {
  Timer? _timer;
  // clock.now(), not DateTime.now() directly — DateTime.now() can't be
  // intercepted via Zone (confirmed empirically: pumping a test's fake
  // Timer clock forward never moves it), so there'd be no seam-free way to
  // deterministically test the actual 15-minute-idle-timeout branch below.
  // The unoverridden `clock` global just calls real DateTime.now(), so this
  // changes nothing about production behavior.
  DateTime _lastActivity = clock.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    _scheduleCheck(idleTimeoutDuration);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Catches "backgrounded past the limit" immediately on return, rather
    // than waiting out whatever's left of a timer the OS may have
    // suspended/delayed while backgrounded.
    if (state == AppLifecycleState.resumed) _checkIdle();
  }

  void _registerActivity([PointerEvent? _]) {
    _lastActivity = clock.now();
  }

  bool _onKeyEvent(KeyEvent event) {
    _registerActivity();
    return false; // observe only — never consume/block the actual key event.
  }

  void _scheduleCheck(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, _checkIdle);
  }

  void _checkIdle() {
    final elapsed = clock.now().difference(_lastActivity);
    if (elapsed >= idleTimeoutDuration) {
      if (ref.read(authServiceProvider).isAuthenticated) {
        ref.read(authServiceProvider).signOut();
      }
      _scheduleCheck(idleTimeoutDuration);
    } else {
      // Activity happened more recently than a full timeout ago (the
      // common case — this fires on the original schedule, not necessarily
      // right when idle time is actually up) — recheck after exactly
      // whatever time is genuinely left.
      _scheduleCheck(idleTimeoutDuration - elapsed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _registerActivity,
      onPointerMove: _registerActivity,
      onPointerSignal: _registerActivity,
      child: widget.child,
    );
  }
}
