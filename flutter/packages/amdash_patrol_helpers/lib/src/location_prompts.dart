import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'interaction_helpers.dart';

/// Watches for and clears every location-related prompt a screen using
/// live GPS tracking can show on mount:
///
///  1. The native OS "Allow AmDash to access this device's location?"
///     permission dialog — denied via Patrol's purpose-built permission
///     API (`isPermissionDialogVisible`/`denyPermission`), not by matching
///     button text (tried and retried in two earlier attempts; more
///     robust this way regardless).
///  2. The native Google Play Services "For a better experience, your
///     device will need to use Location Accuracy" dialog — only possible
///     if permission *is* granted but device accuracy settings aren't, so
///     denying (1) should mean this never actually fires anymore; checked
///     anyway as cheap, harmless defense-in-depth.
///  3. The in-app "Location permission is off" `AlertDialog`, once the
///     screen's own geolocation fetch fails (always, here, since (1)
///     denies it). `showDialog`'s default `barrierDismissible: true` means
///     its modal barrier swallows the very next tap dispatched anywhere
///     else on screen — confirmed via a real GHA failure's Playwright
///     accessibility snapshot that an unrelated "submit" tap landed on the
///     barrier and closed the dialog instead of ever reaching the button
///     underneath.
///
/// Checks (1)/(2) (native) before (3) (in-app) on every single iteration,
/// never skipping either — an earlier version of this function skipped
/// the native checks for a whole iteration whenever the in-app dialog's
/// text was found, on the assumption that (1) only ever fires once per
/// screen. Confirmed wrong via a downloaded recording *and* the raw
/// logcat from a real GHA failure: the location service's own periodic
/// re-poll timer calls `Geolocator.requestPermission()` again on every
/// tick, and Android doesn't necessarily treat a single prior "Don't
/// allow" as permanent — the real system dialog can and does pop back up
/// completely independently of whatever the in-app dialog is doing. With
/// the native checks skipped, this function's own `pressBack()` calls
/// (meant for the in-app `AlertDialog`) started landing on that
/// re-appeared native dialog instead of Patrol's purpose-built
/// `denyPermission()` API — the logcat showed a real ANR in Android's own
/// permission activity ("Dispatching key to ... even though there are
/// other unprocessed events" → "Input dispatching timed out ... Waited
/// 5003ms for FocusEvent"), a real Android input-dispatch backlog, not a
/// Flutter-level issue. Checking both every iteration costs a bit of
/// latency (each native check blocks for up to 500ms even when it finds
/// nothing) but means a re-appeared native dialog is always routed to the
/// API actually meant for it.
///
/// The outer time bound is a safety net against a genuinely stuck dialog,
/// not a normal operating budget: confirmed for real (via a downloaded
/// recording, frame by frame) that an earlier, shorter fixed bound
/// abandoned an *actively-being-dismissed* dialog partway through — this
/// only returns via the idle path below (nothing left to handle for two
/// consecutive iterations), never by running out of clock while still
/// actively finding something to dismiss every pass.
Future<void> settleLocationPrompts(PatrolIntegrationTester $) async {
  final ceiling = DateTime.now().add(const Duration(seconds: 45));
  final grace = DateTime.now().add(const Duration(seconds: 8));
  var everHandledSomething = false;
  var consecutiveMisses = 0;
  while (DateTime.now().isBefore(ceiling)) {
    var handledSomething = false;

    if (!kIsWeb) {
      if (await $.platform.mobile.isPermissionDialogVisible(timeout: const Duration(milliseconds: 500))) {
        handledSomething = true;
        try {
          await $.platform.mobile.denyPermission();
        } catch (_) {
          // Best-effort — see this function's own doc comment.
        }
        // Longer than the other post-action pumps in this function — real
        // GHA evidence (a downloaded logcat) showed a single native call
        // taking nearly 7 real seconds on a loaded Test Lab device, and
        // looping back too soon risks firing another native call before
        // Android's own input dispatch has caught up, which is exactly
        // the sequence that produced a real ANR in Android's permission
        // activity in that same run.
        await $.pump(const Duration(milliseconds: 800));
      }

      try {
        await $.platform.tap(Selector(text: 'No thanks'), timeout: const Duration(milliseconds: 500));
        handledSomething = true;
        await $.pump(const Duration(milliseconds: 300));
      } catch (_) {
        // Not present this pass — see this function's own doc comment.
      }
    }

    // Scoped to the dialog's own title, NOT any inline "Could not get your
    // current location..." banner text a screen might also show — a real
    // bug, confirmed via a real GHA failure: that banner stays permanently
    // present in the form for the rest of its lifetime once the location
    // error occurs, so checking for it stayed "true" long after the
    // dialog itself had already been dismissed, and this function kept
    // calling pressBack() anyway on every later iteration — with no
    // dialog left to dismiss, that just navigated the app itself back out
    // of the screen entirely. This dialog's own title only exists while
    // it's actually mounted.
    if (find.text('Location permission is off').evaluate().isNotEmpty) {
      handledSomething = true;
      if (kIsWeb) {
        // Tapping the OK button directly is the only option on web — no
        // native automation there. Already established reliable on this
        // path from many earlier runs.
        final okButton = find.widgetWithText(TextButton, 'OK');
        if (okButton.evaluate().isNotEmpty) {
          try {
            await tapFinder($, okButton);
          } catch (_) {
            // Retried on the next loop iteration regardless.
          }
        }
      } else {
        // On Android, tapping the OK button directly turned out
        // completely unreliable under this function's own sustained
        // native-automation load — confirmed for real via a downloaded
        // recording where dozens of "successful" taps across two full
        // settleLocationPrompts calls (40+ seconds combined) never once
        // actually closed the dialog. AlertDialog is dismissible via the
        // Android back button by default (no PopScope/WillPopScope
        // blocking it here), and the back button goes through real
        // Android input dispatch rather than a synthetic Flutter-level
        // tap that has to land pixel-precisely on this exact button — a
        // completely different, more robust dismissal path. Only reached
        // once the dialog's error text is confirmed on screen, so this
        // can't accidentally navigate the app itself backward.
        try {
          // ignore: deprecated_member_use
          await $.native.pressBack();
        } catch (_) {
          // Best-effort — retried on the next loop iteration regardless.
        }
      }
      await $.pump(const Duration(milliseconds: 300));
    }

    if (handledSomething) {
      everHandledSomething = true;
      consecutiveMisses = 0;
    } else {
      consecutiveMisses++;
      final gracePassed = DateTime.now().isAfter(grace);
      if (consecutiveMisses >= 2 && (everHandledSomething || gracePassed)) {
        return;
      }
      await $.pump(const Duration(milliseconds: 500));
    }
  }
}

/// Narrower than [settleLocationPrompts]: only the native Google Play
/// Services "Location Accuracy" dialog, not the fuller battery of
/// permission/in-app-dialog handling — for a test that only runs on
/// Chrome (a no-op there; see the `kIsWeb` guard) but whose screen goes
/// through the exact same location-mount path a mobile run would, so this
/// keeps the fix available if that test is ever run on Android too.
Future<void> dismissNativeLocationAccuracyDialog(PatrolIntegrationTester $) async {
  if (kIsWeb) return;
  for (var i = 0; i < 2; i++) {
    try {
      await $.platform.tap(Selector(text: 'No thanks'), timeout: const Duration(seconds: 2));
      await $.pump(const Duration(milliseconds: 300));
    } catch (_) {
      break;
    }
  }
}
