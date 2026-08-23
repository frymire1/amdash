// Phase 5-ish verification (added after Phases 1-4): runs via `patrol test
// --device chrome` against real Chrome, real Firebase Auth/Firestore on
// amdash-dev. Unlike physician/admin's Patrol tests, this one creates,
// edits, and deletes its own throwaway patient entirely through the app's
// own UI — the runner script only needs to create/delete the throwaway EMS
// account itself (see nx-monorepo/scripts/run-ems-patrol-test.mjs).
import 'package:ems/firebase_options.dart';
import 'package:ems/main.dart';
import 'package:ems/screens/home_screen.dart';
import 'package:ems/screens/patient_upload_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otp/otp.dart';
import 'package:patrol/patrol.dart';

// Patrol's own `.tap()` requires a widget to pass its hit-testable check,
// which proved unreliable against this app family's Material overlays on
// Flutter Web/CanvasKit through Patrol's Playwright-backed web runner (see
// admin's and physician's patrol_test files for the full story). Raw
// $.tester.tap() (only requires the widget to exist, then simulates the
// tap at its computed center) doesn't have this problem.
//
// Unlike admin/physician, this screen's own ensureVisible() calls proved
// unreliable here too — confirmed reproducibly failing with "Bad state: No
// element" on more than one different, definitely-present widget (a
// SwitchListTile, then later a keyed FilledButton), most likely because
// this form's Riverpod watches (uploadedPatientsProvider,
// hospitalNamesProvider) rebuild it on every Firestore snapshot, and
// ensureVisible's own multi-step scroll-then-recheck process can land on
// exactly the wrong instant mid-rebuild. The form fits on screen without
// real scrolling anyway, so attempt it best-effort and swallow a failure
// rather than let it abort the whole tap.
Future<void> tapFinder(PatrolIntegrationTester $, Finder finder) async {
  try {
    await $.tester.ensureVisible(finder);
  } catch (_) {
    // Best-effort — see comment above.
  }
  await $.pump(const Duration(milliseconds: 200));
  await $.tester.tap(finder);
  await $.pump(const Duration(milliseconds: 400));
}

Future<void> tapText(PatrolIntegrationTester $, String text) =>
    tapFinder($, find.text(text));

Future<void> tapKey(PatrolIntegrationTester $, String key) =>
    tapFinder($, find.byKey(Key(key)));

/// Patrol's own $(TextField).at(index).enterText() has the same
/// hit-testable-check unreliability as its .tap() (see tapFinder's
/// comment above) — confirmed for real: a GHA run found the Healthcare
/// Number field existing but not yet hit-testable, timing out Patrol's
/// own internal 10s wait. Raw $.tester.enterText() only requires the
/// widget to exist, same fix as tapFinder already applies to taps.
///
/// Also waits for the field to exist at all before touching it — not
/// just a fixed short pump — confirmed for real on Android (physician's
/// patient_flow_test.dart, this exact helper copied there): unlike
/// Patrol's own high-level .enterText() (which waits up to 10s before
/// acting), a raw enterText with no existence check threw a bare
/// RangeError when called right after a route transition whose TextField
/// hadn't mounted yet, even though the *screen* had already visibly
/// changed (e.g. new title text present).
Future<void> enterTextAt(
  PatrolIntegrationTester $,
  int index,
  String text,
) async {
  for (var i = 0; i < 20; i++) {
    if (find.byType(TextField).evaluate().length > index) break;
    await $.pump(const Duration(milliseconds: 200));
  }
  final finder = find.byType(TextField).at(index);
  try {
    await $.tester.ensureVisible(finder);
  } catch (_) {
    // Best-effort — see tapFinder's comment above.
  }
  await $.pump(const Duration(milliseconds: 200));
  await $.tester.enterText(finder, text);
  await $.pump(const Duration(milliseconds: 400));
}

/// Polls with fixed pumps rather than a one-shot wait — network round trips
/// (Firestore writes + listener updates) don't always land inside a short
/// fixed pump.
Future<void> pumpUntil(
  PatrolIntegrationTester $,
  bool Function() condition, {
  int maxIterations = 50,
}) async {
  for (var i = 0; i < maxIterations; i++) {
    if (condition()) return;
    await $.pump(const Duration(milliseconds: 400));
  }
}

/// Watches for and clears every location-related prompt
/// `PatientUploadScreen`/`LocationTrackingSection` can show on mount:
///
///  1. The native OS "Allow AmDash to access this device's location?"
///     permission dialog — denied via Patrol's purpose-built permission
///     API (`isPermissionDialogVisible`/`denyPermission`), not by
///     matching button text (tried and retried in two earlier attempts;
///     more robust this way regardless).
///  2. The native Google Play Services "For a better experience, your
///     device will need to use Location Accuracy" dialog — only
///     possible if permission *is* granted but device accuracy settings
///     aren't, so denying (1) should mean this never actually fires
///     anymore; checked anyway as cheap, harmless defense-in-depth.
///  3. `PatientUploadScreen`'s own in-app "Location permission is off"
///     `AlertDialog`, once `LocationTrackingSection` reports its
///     geolocation fetch failed (always, here, since (1) denies it).
///     `showDialog`'s default `barrierDismissible: true` means its
///     modal barrier swallows the very next tap dispatched anywhere else
///     on screen — confirmed via a real GHA failure's Playwright
///     accessibility snapshot that an unrelated "submit" tap landed on
///     the barrier and closed the dialog instead of ever reaching the
///     button underneath.
///
/// (3) does NOT recur every 15s despite `LocationTrackingSection` re-
/// polling location on that interval — `patient_upload_screen.dart` only
/// ever opens it once per mount (`_locationErrorDialogShown` guards the
/// post-frame callback that shows it). An earlier version of this doc
/// comment claimed it recurred; that was wrong, caught by scrubbing a
/// downloaded recording frame-by-frame and finding zero gaps in the
/// dialog's on-screen presence between when it first appeared and when
/// this function finally cleared it — a single continuous instance the
/// whole time, not several. So there is exactly one dialog to clear per
/// screen, and this function's only real job is to not give up on it
/// early.
///
/// That same recording is what caught the actual bug: the dialog stayed
/// up for ~70s despite this function being called right at mount, because
/// its old fixed 20s-per-call bound would abandon an *actively-being-
/// dismissed* dialog partway through, and nothing watched for it again
/// until the second call right before submit — by which point the field-
/// filling in between had eaten most of that gap. Fixed by treating the
/// outer time bound as a safety net for a genuinely stuck dialog, not a
/// normal operating budget: the loop only returns via the idle path below
/// (nothing left to handle for two consecutive iterations), never by
/// running out of clock while still actively finding something to
/// dismiss every pass.
///
/// Checks (1)/(2) (native) before (3) (in-app) on every single iteration,
/// never skipping either — an earlier version of this function skipped
/// the native checks for a whole iteration whenever the in-app dialog's
/// text was found, on the assumption that (1) only ever fires once per
/// screen. Confirmed wrong via a downloaded recording *and* the raw
/// logcat from a real GHA failure: `LocationTrackingSection`'s 15s
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
/// 5003ms for FocusEvent"), which is a real Android input-dispatch
/// backlog, not a Flutter-level issue. Checking both every iteration
/// costs a bit of latency (each native check blocks for up to 500ms even
/// when it finds nothing) but means a re-appeared native dialog is always
/// routed to the API actually meant for it.
Future<void> settleLocationPrompts(PatrolIntegrationTester $) async {
  // Safety net against a genuinely stuck dialog, not a normal budget —
  // see this function's own doc comment.
  final ceiling = DateTime.now().add(const Duration(seconds: 45));
  final grace = DateTime.now().add(const Duration(seconds: 8));
  var everHandledSomething = false;
  var consecutiveMisses = 0;
  while (DateTime.now().isBefore(ceiling)) {
    var handledSomething = false;

    if (!kIsWeb) {
      if (await $.platform.mobile.isPermissionDialogVisible(
        timeout: const Duration(milliseconds: 500),
      )) {
        handledSomething = true;
        try {
          await $.platform.mobile.denyPermission();
        } catch (_) {
          // Best-effort — see this function's own doc comment.
        }
        // Longer than the other post-action pumps in this function —
        // real GHA evidence (a downloaded logcat) showed a single native
        // call taking nearly 7 real seconds on a loaded Test Lab device,
        // and looping back too soon risks firing another native call
        // before Android's own input dispatch has caught up, which is
        // exactly the sequence that produced a real ANR in Android's
        // permission activity in that same run.
        await $.pump(const Duration(milliseconds: 800));
      }

      try {
        await $.platform.tap(
          Selector(text: 'No thanks'),
          timeout: const Duration(milliseconds: 500),
        );
        handledSomething = true;
        await $.pump(const Duration(milliseconds: 300));
      } catch (_) {
        // Not present this pass — see this function's own doc comment.
      }
    }

    // Scoped to the dialog's own title, NOT LocationTrackingSection's
    // inline "Could not get your current location..." banner text (an
    // earlier version of this check used that instead — a real bug,
    // confirmed via a real GHA failure: that banner is permanently
    // present in the form for the rest of its lifetime once the location
    // error occurs, so that check stayed "true" long after the dialog
    // itself had already been dismissed, and this function kept calling
    // pressBack() anyway on every later iteration — with no dialog left
    // to dismiss, that just navigated the app itself back out of
    // PatientUploadScreen entirely). This dialog's own title only exists
    // while it's actually mounted.
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

/// Every account requires TOTP MFA (`AppRouteGuard`'s `requireMfa` tier,
/// checked right after auth) — a freshly created throwaway account has
/// never enrolled, so sign-in always lands on /mfa-setup first. See
/// admin's user_flow_test.dart for the full rationale (no server-side
/// shortcut exists; this drives the real enrollment UI with a computed
/// code instead of bypassing it). The account is created with
/// emailVerified: true already (see run-ems-patrol-test.mjs), so
/// /mfa-setup skips straight to the TOTP step.
Future<void> completeMfaEnrollment(PatrolIntegrationTester $) async {
  await pumpUntil(
    $,
    () => find.byKey(const Key('mfa_secret_key')).evaluate().isNotEmpty,
    maxIterations: 40,
  );
  final secret = $.tester
      .widget<SelectableText>(find.byKey(const Key('mfa_secret_key')))
      .data!;
  final code = OTP.generateTOTPCodeString(
    secret,
    DateTime.now().millisecondsSinceEpoch,
    algorithm: Algorithm.SHA1,
    isGoogle: true,
  );
  await enterTextAt($, 0, code);
  await tapText($, 'Confirm');
  await pumpUntil(
    $,
    () => find.byKey(const Key('mfa_secret_key')).evaluate().isEmpty,
    maxIterations: 30,
  );
}

void main() {
  patrolTest('signs in, adds a patient, edits it, and deletes it', ($) async {
    const email = String.fromEnvironment('SMOKE_EMAIL');
    const password = String.fromEnvironment('SMOKE_PASSWORD');
    expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
    expect(
      password,
      isNotEmpty,
      reason: 'pass --dart-define=SMOKE_PASSWORD=...',
    );

    final patientName =
        'Patrol EMS Test Patient ${DateTime.now().millisecondsSinceEpoch}';

    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await $.pumpWidgetAndSettle(const ProviderScope(child: EmsApp()));

    // Sign in. Was Patrol's own $(TextField).at(0).enterText() — reliable
    // all session on Chrome, but this is the first time this exact line
    // ever ran for real on Android (Firebase Test Lab's Android e2e job
    // had been silently running zero tests until the native Patrol setup
    // was fixed — see android/app/src/androidTest/.../MainActivityTest.java).
    // First real run hit the identical hit-test unreliability
    // enterTextAt's own doc comment already covers, just on a different
    // platform/renderer than where it was originally found.
    await enterTextAt($, 0, email);
    await tapText($, 'Continue');
    await pumpUntil($, () => find.text('Sign In').evaluate().isNotEmpty);
    await enterTextAt($, 0, password);
    await tapText($, 'Sign In');

    await completeMfaEnrollment($);

    // Was $(HomeScreen).waitUntilVisible(...) — Patrol's own hit-test
    // check proved unreliable on Flutter Web here (confirmed for the
    // physician app's equivalent MainViewScreen check via a real GHA
    // run's Playwright accessibility snapshot showing the screen was
    // actually fully rendered at the moment it "failed" to be
    // hit-testable — see patient_flow_test.dart's fuller comment on this
    // same fix). pumpUntil + find.byType().evaluate() checks existence,
    // not hit-testability, and is the proven pattern throughout this
    // codebase (admin's user_flow_test.dart relies on it exclusively).
    await pumpUntil(
      $,
      () => find.byType(HomeScreen).evaluate().isNotEmpty,
      maxIterations: 50,
    );

    // Add a patient. Fields, by index, on this form: 0=Name, 1=Age,
    // 2=Healthcare Number, 3=Heart Rate (Gender/Destination Hospital are
    // dropdowns, not TextFields, and aren't required to submit).
    await tapText($, 'Add Patient');
    await pumpUntil(
      $,
      () => find.byType(PatientUploadScreen).evaluate().isNotEmpty,
    );
    await settleLocationPrompts($);
    await enterTextAt($, 0, patientName);
    await enterTextAt($, 2, 'TEST-12345');
    await enterTextAt($, 3, '80');
    // Live tracking calls Geolocator.getCurrentPosition, which needs a
    // real, granted browser geolocation permission this CI environment
    // doesn't have — turn it off so submit doesn't depend on that.
    // Target the SwitchListTile itself, not find.byType(Switch) — the
    // whole row is the real tap target (Material spec), and the inner
    // Switch alone didn't resolve to a match in an earlier attempt.
    await tapFinder($, find.byType(SwitchListTile));
    // Re-checked immediately before the tap, not just once right after
    // mount — LocationTrackingSection's 15s re-poll timer can pop a fresh
    // dialog at any point the form stays open, and its modal barrier
    // would otherwise swallow this exact tap instead of ever reaching
    // the real submit button (confirmed for real via a downloaded
    // recording: the edit flow's own equivalent submit silently landed
    // on a barrier from a dialog that reappeared after the earlier
    // settleLocationPrompts call had already returned).
    await settleLocationPrompts($);
    await tapKey($, 'patient_upload_submit');
    await pumpUntil(
      $,
      () => find.text(patientName).evaluate().isNotEmpty,
      maxIterations: 40,
    );
    expect(
      find.text(patientName),
      findsOneWidget,
      reason: 'patient should appear on the home screen after upload',
    );

    // Edit it — scope Edit/Delete to this specific patient's own card
    // (not by text alone, since test-org can have other patients whose
    // cards render the exact same "Edit"/"Delete" button text). The
    // home screen rebuilds on every Firestore snapshot from its own
    // live uploadedPatientsProvider watch, so — same lesson as
    // tapFinder's ensureVisible above — wait for the compound finder to
    // actually resolve before tapping it, not just once at call time.
    Finder cardButtonFor(String name, String buttonLabel) => find.descendant(
      of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
      matching: find.widgetWithText(OutlinedButton, buttonLabel),
    );

    Future<void> tapCardButton(String buttonLabel) async {
      final finder = cardButtonFor(patientName, buttonLabel);
      // Retries the whole find-then-tap cycle, not just the initial wait —
      // confirmed via a real GHA failure on Firebase Test Lab's ARM virtual
      // device: pumpUntil found the button, but tapFinder's own tap() threw
      // "Found 0 widgets ... could not find any matching widgets" on the
      // very same finder moments later. The home screen rebuilds on every
      // Firestore snapshot from its own live uploadedPatientsProvider watch
      // (see cardButtonFor's own comment above), and that gap between
      // pumpUntil's check and tap()'s own re-evaluation is apparently wide
      // enough for one of those rebuilds to land in between. Re-running the
      // full wait-then-tap cycle rides out a single bad rebuild.
      for (var attempt = 0; attempt < 3; attempt++) {
        await pumpUntil(
          $,
          () => finder.evaluate().isNotEmpty,
          maxIterations: 30,
        );
        try {
          await tapFinder($, finder);
          return;
        } catch (_) {
          if (attempt == 2) rethrow;
          await $.pump(const Duration(milliseconds: 300));
        }
      }
    }

    await tapCardButton('Edit');
    await pumpUntil(
      $,
      () => find.byType(PatientUploadScreen).evaluate().isNotEmpty,
    );
    // Wait for the async prefill (reads the uploaded-patients list) to
    // land before touching a field, or a fast enterText can race it and
    // get silently overwritten a moment later.
    await pumpUntil(
      $,
      () => find.text(patientName).evaluate().isNotEmpty,
      maxIterations: 40,
    );
    await settleLocationPrompts($);
    await enterTextAt($, 3, '95');
    // Re-checked again immediately before the tap — see the Add flow's
    // identical call above for why (this is the exact spot a real GHA
    // failure confirmed it happening).
    await settleLocationPrompts($);
    await tapKey($, 'patient_upload_submit');
    await pumpUntil(
      $,
      () => find.text('95 bpm').evaluate().isNotEmpty,
      maxIterations: 40,
    );
    expect(
      find.text('95 bpm'),
      findsOneWidget,
      reason: 'edited heart rate should show on the home screen',
    );

    // Delete it.
    await tapCardButton('Delete');
    await pumpUntil(
      $,
      () => find.text('Delete patient?').evaluate().isNotEmpty,
    );
    // The dialog's own confirm button is a FilledButton — distinct from
    // the card's OutlinedButton of the same label, so no extra scoping
    // needed to avoid hitting the card's button again by mistake.
    await tapFinder($, find.widgetWithText(FilledButton, 'Delete'));
    await pumpUntil(
      $,
      () => find.text(patientName).evaluate().isEmpty,
      maxIterations: 40,
    );
    expect(
      find.text(patientName),
      findsNothing,
      reason: 'patient should be gone after delete',
    );
  });
}
