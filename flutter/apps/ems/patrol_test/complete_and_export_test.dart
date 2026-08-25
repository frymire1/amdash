// Verifies the FHIR export flow end to end: upload a patient with a known
// heart rate, complete transport (which triggers an automatic FHIR export
// right after — see patient_summary_card.dart's _completeTransport /
// _autoExportFhir for why this isn't gated behind its own confirmation
// dialog or button), and assert the *actual* heart-rate value the
// callable's real response contained matches what was entered — not just
// that the export call didn't throw. Checked via amdash_core's
// debugLastExportResult/debugLastExportError (an in-process capture, not
// a widget scan — this card is expected to unmount shortly after
// completing transport, well before the export itself finishes). A
// separate file (not folded into ems_test.dart) so a failure here is
// unambiguous about which scenario broke, matching this app's existing
// one-scenario-per-file convention (see patient_upload_flow_test.dart).
// Chrome-only — see run-ems-patrol-test.mjs, which doesn't wire this into
// the Firebase Test Lab (Android) path, the same way
// run-patient-flow-e2e.mjs's cross-app test also stays web-only.
import 'package:amdash_core/amdash_core.dart';
import 'package:amdash_patrol_helpers/amdash_patrol_helpers.dart';
import 'package:ems/firebase_options.dart';
import 'package:ems/main.dart';
import 'package:ems/screens/home_screen.dart';
import 'package:ems/screens/patient_upload_screen.dart';
import 'package:ems/services/patient_upload_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

void main() {
  patrolTest('signs in, completes transport, and exports a FHIR record', (
    $,
  ) async {
    const email = String.fromEnvironment('SMOKE_EMAIL');
    const password = String.fromEnvironment('SMOKE_PASSWORD');
    expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
    expect(
      password,
      isNotEmpty,
      reason: 'pass --dart-define=SMOKE_PASSWORD=...',
    );

    final patientName =
        'Patrol FHIR Export Test Patient ${DateTime.now().millisecondsSinceEpoch}';
    // The value the exported bundle's own heart-rate Observation should
    // echo back exactly (see the assertion below) — proving the round
    // trip (Firestore -> exportPatientFhirBundle's KMS decrypt + FHIR
    // mapping -> the real parsed response) actually carries the right
    // data, not just that some export "succeeded".
    const heartRate = '88';

    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await $.pumpWidgetAndSettle(const ProviderScope(child: EmsApp()));

    // Captured as soon as the patient is uploaded (see below) and deleted
    // in `finally` regardless of how the rest of this test goes — this
    // test owns cleaning up the exact data it creates, rather than
    // leaving it for some other process to eventually sweep away.
    String? patientId;
    try {
      await enterTextAt($, 0, email);
      await tapText($, 'Continue');
      await pumpUntil($, () => find.text('Sign In').evaluate().isNotEmpty);
      await enterTextAt($, 0, password);
      await tapText($, 'Sign In');

      // This shared smoke account may already have MFA enrolled —
      // run-ems-patrol-test.mjs runs ems_test.dart against the same seeded
      // account first, and enrollment is one-time per account, so this run
      // can land straight on HomeScreen instead of /mfa-setup. Wait for
      // whichever actually happens rather than assuming enrollment is
      // always needed (confirmed for real: a first attempt at this file
      // assumed unconditionally and failed with "Bad state: No element" —
      // find.byKey('mfa_secret_key') never appears when sign-in skips
      // straight past an already-enrolled account).
      await pumpUntil(
        $,
        () =>
            find.byKey(const Key('mfa_secret_key')).evaluate().isNotEmpty ||
            find.byType(HomeScreen).evaluate().isNotEmpty,
        maxIterations: 50,
      );
      if (find.byKey(const Key('mfa_secret_key')).evaluate().isNotEmpty) {
        await completeMfaEnrollment($);
      }

      await pumpUntil(
        $,
        () => find.byType(HomeScreen).evaluate().isNotEmpty,
        maxIterations: 50,
      );

      // Add a patient. Fields, by index: 0=Name, 1=Age, 2=Healthcare Number,
      // 3=Heart Rate (Gender/Destination Hospital are dropdowns, not
      // TextFields, and aren't required to submit) — see ems_test.dart.
      await tapText($, 'Add Patient');
      await pumpUntil(
        $,
        () => find.byType(PatientUploadScreen).evaluate().isNotEmpty,
      );
      await settleLocationPrompts($);
      await enterTextAt($, 0, patientName);
      await enterTextAt($, 2, 'TEST-FHIR-12345');
      await enterTextAt($, 3, heartRate);
      // Live tracking off — same reasoning as ems_test.dart's identical
      // step: this CI environment has no real, granted browser geolocation.
      await tapFinder($, find.byType(SwitchListTile));
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
      patientId = PatientUploadService.debugLastUploadedPatientId;
      expect(
        patientId,
        isNotNull,
        reason: 'uploadPatient should have set debugLastUploadedPatientId',
      );

      // Scoped to this specific patient's own card — same reasoning as
      // ems_test.dart's identical helpers (test-org can have other
      // patients whose cards render the exact same button text).
      Finder cardButtonFor(String buttonLabel) => find.descendant(
        of: find.ancestor(
          of: find.text(patientName),
          matching: find.byType(Card),
        ),
        matching: find.widgetWithText(OutlinedButton, buttonLabel),
      );

      Future<void> tapCardButton(String buttonLabel) async {
        final finder = cardButtonFor(buttonLabel);
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

      // Complete transport — this chains directly into an automatic FHIR
      // export (see patient_summary_card.dart's _completeTransport /
      // _autoExportFhir for why there's no separate confirmation dialog or
      // button for the export itself): completing transport removes this
      // patient from this screen's own active-only list immediately
      // (patient_session_service.dart), and this card is correctly
      // *unmounted*, not reused, once it does (see home_screen.dart's own
      // comment on why each card is keyed by patient id) — so there's no
      // later moment a separately-discoverable export button/dialog
      // anchored to *this* card could ever reliably work. run-ems-patrol-
      // test.mjs seeds fhirExportEnabled: true on test-org, so the export
      // should fire here automatically.
      debugLastExportResult = null;
      debugLastExportError = null;
      await tapCardButton('Complete Transport');
      await pumpUntil(
        $,
        () => find.text('Complete transport?').evaluate().isNotEmpty,
      );
      await tapFinder(
        $,
        find.widgetWithText(FilledButton, 'Complete Transport'),
      );

      // The real assertion: a genuine round trip through
      // exportPatientFhirBundle (functions/src/patients.ts) — org lookup,
      // status precondition, KMS decrypt path, FHIR resource mapping, audit
      // log — with the actual exported heart-rate Observation's value read
      // back out of the callable's real response. Checked via
      // amdash_core's debugLastExportResult/debugLastExportError (an
      // in-process capture — see its own doc comment) rather than a widget
      // in this card's own tree: this card is expected to unmount shortly
      // after completing transport, well before the export (which runs
      // against a widget-independent ProviderContainer — see
      // _autoExportFhir) actually finishes, so there's no guaranteed-
      // still-around success/error Text to scan for instead.
      await pumpUntil(
        $,
        () => debugLastExportResult != null || debugLastExportError != null,
        maxIterations: 100,
      );
      if (debugLastExportError != null) {
        fail('Export failed: $debugLastExportError');
      }
      final bundle = debugLastExportResult!.bundle;
      final actualHeartRate = latestObservationValue(bundle, loincHeartRate);
      expect(
        actualHeartRate,
        int.parse(heartRate),
        reason:
            "the exported FHIR bundle's heart rate observation should match what was actually entered for this "
            'patient (actual bundle heart-rate observation: $actualHeartRate)',
      );
    } finally {
      // Deletes this test's own patient directly, rather than leaving it
      // for run-ems-patrol-test.mjs's own cleanup() sweep to eventually
      // notice and remove once this run's throwaway account is deleted —
      // that sweep is a real backstop for a genuinely interrupted run
      // (see its own comment), not something this test should rely on for
      // its *own* routine cleanup. Reuses the app's own
      // patientUploadServiceProvider (via the still-mounted HomeScreen's
      // own ProviderScope) rather than constructing a fresh
      // PatientUploadService by hand, so this goes through the exact same
      // deletePatientRecord callable the app's own Delete button calls —
      // no separate construction logic to keep in sync. Runs regardless
      // of whether the test above passed or failed, as long as the patient
      // was actually created (completing transport doesn't remove the
      // Firestore document itself, only this screen's own active-only
      // list membership — see home_screen.dart — so this is still needed
      // even after a successful export).
      if (patientId != null && find.byType(HomeScreen).evaluate().isNotEmpty) {
        try {
          final container = ProviderScope.containerOf(
            $.tester.element(find.byType(HomeScreen)),
            listen: false,
          );
          await container.read(patientUploadServiceProvider).deletePatient(patientId);
        } catch (_) {
          // Best-effort — run-ems-patrol-test.mjs's own cleanup() sweep is
          // still a backstop if this somehow fails.
        }
      }
    }
  });
}
