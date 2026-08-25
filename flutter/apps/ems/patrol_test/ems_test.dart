// Phase 5-ish verification (added after Phases 1-4): runs via `patrol test
// --device chrome` against real Chrome, real Firebase Auth/Firestore on
// amdash-dev. Unlike physician/admin's Patrol tests, this one creates,
// edits, and deletes its own throwaway patient entirely through the app's
// own UI — the runner script only needs to create/delete the throwaway EMS
// account itself (see nx-monorepo/scripts/run-ems-patrol-test.mjs).
//
// tapFinder/enterTextAt/pumpUntil/settleLocationPrompts/
// completeMfaEnrollment come from amdash_patrol_helpers, shared across
// every app's patrol_test/ suite — see that package for the full
// rationale/history behind each one.
import 'package:amdash_patrol_helpers/amdash_patrol_helpers.dart';
import 'package:ems/firebase_options.dart';
import 'package:ems/main.dart';
import 'package:ems/screens/home_screen.dart';
import 'package:ems/screens/patient_upload_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

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

    // Raw delete action, no assertions — reused below both for the test's
    // own real, asserted delete and as a best-effort cleanup attempt if
    // something else fails first (see the try/finally around the rest of
    // this test).
    Future<void> deletePatient() async {
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
    }

    // From here on, the patient definitely exists in Firestore — wrap the
    // rest of the test (editing it, then deleting it for real) so a
    // failure partway through the edit still attempts to delete it,
    // instead of just leaving it orphaned for run-ems-patrol-test.mjs's
    // own createdBy-based sweep to eventually catch on some future run.
    // That sweep is still the real, guaranteed-to-work safety net for
    // whatever this can't manage (e.g. the app itself too broken to find/
    // tap Delete after some failures) — this just means the common case
    // doesn't have to wait for it.
    try {
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

      await deletePatient();
      expect(
        find.text(patientName),
        findsNothing,
        reason: 'patient should be gone after delete',
      );
    } finally {
      // Only reached if the try block above never got to (or never
      // finished) its own deletePatient() call — a normal pass already
      // leaves nothing for this to find.
      if (find.text(patientName).evaluate().isNotEmpty) {
        try {
          await deletePatient();
        } catch (_) {
          // Best-effort — see this block's own comment above.
        }
      }
    }
  });
}
