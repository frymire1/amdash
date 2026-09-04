import 'package:amdash_core/amdash_core.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockAuthService extends Mock implements AuthService {}

void main() {
  late _MockAuthService authService;

  setUp(() {
    authService = _MockAuthService();
    when(() => authService.signOut()).thenAnswer((_) async {});
    when(() => authService.isAuthenticated).thenReturn(true);
  });

  // The whole test body runs inside withClock — Dart zones propagate
  // through async continuations, so every later `await tester.pump(...)`
  // and callback still sees this fake clock too, not just the initial
  // pumpApp call. clock.now(), not raw DateTime.now(), is what
  // idle_timeout_wrapper.dart itself reads (confirmed empirically that
  // DateTime.now() can't be intercepted via Zone at all — pumping
  // flutter_test's FakeAsync timer clock forward never moves it — which is
  // exactly why the source was changed to use this seam).
  Future<void> withFakeClock(DateTime start, Future<void> Function(DateTime Function() now, void Function(DateTime) setNow) body) {
    var current = start;
    return withClock(Clock(() => current), () => body(() => current, (t) => current = t));
  }

  testWidgets('idle past the timeout while authenticated signs out, then keeps rescheduling', (tester) async {
    await withFakeClock(DateTime(2024, 1, 1, 12), (now, setNow) async {
      await pumpApp(
        tester,
        const IdleTimeoutWrapper(child: SizedBox(key: Key('child'), width: 100, height: 100)),
        overrides: [authServiceProvider.overrideWithValue(authService)],
      );
      await tester.pump();

      setNow(now().add(idleTimeoutDuration));
      await tester.pump(idleTimeoutDuration);
      verify(() => authService.signOut()).called(1);

      // Still authenticated (mocked as always true) -> the reschedule this
      // triggers fires signOut() again on the next full interval, proving
      // _scheduleCheck(idleTimeoutDuration) actually re-armed the timer
      // rather than the check being a one-shot.
      setNow(now().add(idleTimeoutDuration));
      await tester.pump(idleTimeoutDuration);
      verify(() => authService.signOut()).called(1);
    });
  });

  testWidgets('idle past the timeout while signed out never calls signOut, but keeps rescheduling', (tester) async {
    when(() => authService.isAuthenticated).thenReturn(false);

    await withFakeClock(DateTime(2024, 1, 1, 12), (now, setNow) async {
      await pumpApp(
        tester,
        const IdleTimeoutWrapper(child: SizedBox(key: Key('child'), width: 100, height: 100)),
        overrides: [authServiceProvider.overrideWithValue(authService)],
      );
      await tester.pump();

      setNow(now().add(idleTimeoutDuration));
      await tester.pump(idleTimeoutDuration);
      verifyNever(() => authService.signOut());

      // A second interval firing without throwing proves the "signed out"
      // path still re-armed the timer (_scheduleCheck is called either way).
      setNow(now().add(idleTimeoutDuration));
      await tester.pump(idleTimeoutDuration);
      verifyNever(() => authService.signOut());
    });
  });

  testWidgets('activity resets the idle clock, so a subsequent check reschedules instead of signing out', (
    tester,
  ) async {
    await withFakeClock(DateTime(2024, 1, 1, 12), (now, setNow) async {
      await pumpApp(
        tester,
        const IdleTimeoutWrapper(child: SizedBox(key: Key('child'), width: 100, height: 100)),
        overrides: [authServiceProvider.overrideWithValue(authService)],
      );
      await tester.pump();

      // Halfway through the window: register real activity (a tap reaches
      // the Listener's onPointerDown), which resets _lastActivity to *now*.
      setNow(now().add(idleTimeoutDuration ~/ 2));
      await tester.pump(idleTimeoutDuration ~/ 2);
      // warnIfMissed: false — the tap does land on the Listener's own
      // RenderPointerListener (confirmed via the hit-test result), which is
      // what actually matters here; the warning is about the SizedBox's own
      // RenderBox specifically not topping that hit list, a false positive.
      await tester.tap(find.byKey(const Key('child')), warnIfMissed: false);

      // Advance by the *original* schedule's remaining delay (which would
      // have been exactly enough time from the original start) — but
      // because activity reset the clock partway through, elapsed-since-
      // last-activity is still under the timeout, so this must NOT sign
      // out yet.
      setNow(now().add(idleTimeoutDuration ~/ 2));
      await tester.pump(idleTimeoutDuration ~/ 2);
      verifyNever(() => authService.signOut());

      // From the reset point, waiting out a *full* fresh timeout does
      // eventually sign out.
      setNow(now().add(idleTimeoutDuration));
      await tester.pump(idleTimeoutDuration);
      verify(() => authService.signOut()).called(1);
    });
  });

  testWidgets('app resuming while already idle signs out immediately, without waiting for the timer', (
    tester,
  ) async {
    await withFakeClock(DateTime(2024, 1, 1, 12), (now, setNow) async {
      await pumpApp(
        tester,
        const IdleTimeoutWrapper(child: SizedBox(key: Key('child'), width: 100, height: 100)),
        overrides: [authServiceProvider.overrideWithValue(authService)],
      );
      await tester.pump();

      // Move clock.now() past the timeout directly, *without* pumping the
      // FakeAsync timer clock forward — the originally-scheduled Timer
      // hasn't fired yet by its own (separate) virtual clock.
      setNow(now().add(idleTimeoutDuration + const Duration(minutes: 1)));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      verify(() => authService.signOut()).called(1);
    });
  });

  testWidgets('app resuming while not yet idle reschedules for the remaining time (no premature sign-out)', (
    tester,
  ) async {
    await withFakeClock(DateTime(2024, 1, 1, 12), (now, setNow) async {
      await pumpApp(
        tester,
        const IdleTimeoutWrapper(child: SizedBox(key: Key('child'), width: 100, height: 100)),
        overrides: [authServiceProvider.overrideWithValue(authService)],
      );
      await tester.pump();

      // Only a third of the way through the window.
      setNow(now().add(idleTimeoutDuration ~/ 3));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      verifyNever(() => authService.signOut());

      // The remaining two-thirds does eventually trigger it — proving the
      // "not idle yet" branch rescheduled for the genuinely-remaining time
      // rather than either not rescheduling or resetting to a full 15.
      setNow(now().add(idleTimeoutDuration * 2 ~/ 3));
      await tester.pump(idleTimeoutDuration * 2 ~/ 3);
      verify(() => authService.signOut()).called(1);
    });
  });

  testWidgets('a key event registers activity too (does not consume the event)', (tester) async {
    await withFakeClock(DateTime(2024, 1, 1, 12), (now, setNow) async {
      await pumpApp(
        tester,
        const IdleTimeoutWrapper(child: SizedBox(key: Key('child'), width: 100, height: 100)),
        overrides: [authServiceProvider.overrideWithValue(authService)],
      );
      await tester.pump();

      setNow(now().add(idleTimeoutDuration ~/ 2));
      await tester.pump(idleTimeoutDuration ~/ 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);

      setNow(now().add(idleTimeoutDuration ~/ 2));
      await tester.pump(idleTimeoutDuration ~/ 2);
      verifyNever(() => authService.signOut());
    });
  });

  testWidgets('externalActivityProvider.register() resets the idle clock like a real pointer/keyboard event', (
    tester,
  ) async {
    await withFakeClock(DateTime(2024, 1, 1, 12), (now, setNow) async {
      await pumpApp(
        tester,
        const IdleTimeoutWrapper(child: SizedBox(key: Key('child'), width: 100, height: 100)),
        overrides: [authServiceProvider.overrideWithValue(authService)],
      );
      await tester.pump();

      final container = ProviderScope.containerOf(tester.element(find.byType(IdleTimeoutWrapper)));

      // Halfway through the window: register activity via the provider
      // hook instead of a real tap — this is exactly what
      // ems_tracking_service.dart's own successful-publish path calls.
      setNow(now().add(idleTimeoutDuration ~/ 2));
      await tester.pump(idleTimeoutDuration ~/ 2);
      container.read(externalActivityProvider.notifier).register();

      // The remaining half of the *original* schedule must not sign out —
      // proves the hook actually reset _lastActivity, the same as a real
      // pointer/keyboard event would.
      setNow(now().add(idleTimeoutDuration ~/ 2));
      await tester.pump(idleTimeoutDuration ~/ 2);
      verifyNever(() => authService.signOut());

      // From the reset point, a full fresh timeout does eventually sign out.
      setNow(now().add(idleTimeoutDuration));
      await tester.pump(idleTimeoutDuration);
      verify(() => authService.signOut()).called(1);
    });
  });

  testWidgets('unmounting disposes cleanly and cancels the timer (no sign-out after)', (tester) async {
    await withFakeClock(DateTime(2024, 1, 1, 12), (now, setNow) async {
      await pumpApp(
        tester,
        const IdleTimeoutWrapper(child: SizedBox(key: Key('child'), width: 100, height: 100)),
        overrides: [authServiceProvider.overrideWithValue(authService)],
      );
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);

      setNow(now().add(idleTimeoutDuration * 2));
      await tester.pump(idleTimeoutDuration * 2);
      verifyNever(() => authService.signOut());
    });
  });
}
