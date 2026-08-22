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
/// `PatientUploadScreen`/`LocationTrackingSection` can show on mount, in
/// ONE interleaved loop rather than as separate sequential phases:
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
/// None of these wait for this test's own sequencing —
/// `_useCurrentLocation()`'s async chain is a separate, concurrently-
/// running future in the same isolate, not paused by this function's own
/// `await`s — so a dialog can appear (or a new one replace an old one)
/// at any point regardless of which phase this function *thinks* it's
/// in. Confirmed for real via a downloaded Test Lab recording: handling
/// (1) to its own full completion before ever checking for (3) left that
/// second dialog sitting untouched for the better part of a minute on
/// the edit screen, purely because nothing was watching for it yet.
/// Checking all three together, every iteration, removes that dead zone
/// entirely. `LocationTrackingSection` also re-polls location every 15s
/// for as long as the form stays mounted (its own `Timer.periodic`), so
/// any of these can recur — one successful dismissal doesn't mean it
/// stays dismissed, hence looping rather than a single pass.
///
/// Exits once two consecutive iterations find nothing left to do, rather
/// than always blocking for a fixed window — on web, or once Android has
/// nothing further to show, this returns almost immediately instead of
/// wasting the full bound every single call. That early-exit is only
/// armed after either handling at least one prompt, or an initial grace
/// period passes — the async permission request doesn't fire the very
/// instant this function starts polling, so exiting on "found nothing"
/// before it's even had a chance to appear would defeat the point
/// entirely.
Future<void> settleLocationPrompts(PatrolIntegrationTester $) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  final grace = DateTime.now().add(const Duration(seconds: 8));
  var everHandledSomething = false;
  var consecutiveMisses = 0;
  while (DateTime.now().isBefore(deadline)) {
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
        await $.pump(const Duration(milliseconds: 300));
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

    // Scoped to the exact error text, not just any TextButton labeled
    // "OK" — this app has no other dialog that looks like this, but
    // matching narrowly costs nothing and avoids ever depending on that
    // staying true.
    if (find
        .text(
          'Could not get your current location. Please allow location access and try again.',
        )
        .evaluate()
        .isNotEmpty) {
      final okButton = find.widgetWithText(TextButton, 'OK');
      if (okButton.evaluate().isNotEmpty) {
        handledSomething = true;
        try {
          await tapFinder($, okButton);
        } catch (_) {
          // Retried on the next loop iteration regardless — see this
          // function's own doc comment on why a single attempt isn't
          // reliable here.
        }
        await $.pump(const Duration(milliseconds: 300));
      }
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
      await pumpUntil($, () => finder.evaluate().isNotEmpty, maxIterations: 30);
      await tapFinder($, finder);
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
