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
Future<void> enterTextAt(
  PatrolIntegrationTester $,
  int index,
  String text,
) async {
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

/// `PatientUploadScreen` pops an `AlertDialog` ("Location permission is
/// off") the first time `LocationTrackingSection` reports its geolocation
/// fetch failed — always, here, since `webPermissions: []`
/// (run-ems-patrol-test.mjs) denies it outright. `showDialog`'s default
/// `barrierDismissible: true` means its modal barrier swallows the very
/// next tap dispatched anywhere else on screen, dismissing the dialog as a
/// side effect instead of reaching whatever the test actually meant to
/// tap. Confirmed via a real GHA failure's Playwright accessibility
/// snapshot: the edit form was still fully on-screen after a "submit" tap
/// that produced a "would not hit test" warning — the button was never
/// actually pressed, because that tap landed on the barrier and closed the
/// dialog instead. The Add flow above happens to have an earlier tap (the
/// SwitchListTile toggle) that "wastes" itself dismissing the barrier
/// before Save is ever reached, so it doesn't visibly break there — Edit
/// has no such tap in between, so it does. Dismissing the dialog
/// explicitly and deterministically, right after it appears, removes the
/// dependence on an unrelated tap happening to eat it first.
Future<void> dismissLocationPermissionDialog(PatrolIntegrationTester $) async {
  await pumpUntil(
    $,
    () => find
        .text(
          'Could not get your current location. Please allow location access and try again.',
        )
        .evaluate()
        .isNotEmpty,
    maxIterations: 30,
  );
  final okButton = find.widgetWithText(TextButton, 'OK');
  await pumpUntil($, () => okButton.evaluate().isNotEmpty, maxIterations: 10);
  await tapFinder($, okButton);
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
  await $(TextField).enterText(code);
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

    // Sign in.
    await $(TextField).at(0).enterText(email);
    await tapText($, 'Continue');
    await pumpUntil($, () => find.text('Sign In').evaluate().isNotEmpty);
    await $(TextField).at(0).enterText(password);
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
    await dismissLocationPermissionDialog($);
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
    await dismissLocationPermissionDialog($);
    await enterTextAt($, 3, '95');
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
