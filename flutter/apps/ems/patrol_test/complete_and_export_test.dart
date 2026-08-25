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

// Duplicated from ems_test.dart rather than shared — see that file's own
// comment on tapFinder for the full rationale (Patrol's own .tap()'s
// hit-testable check proved unreliable against this app family's Material
// overlays; raw $.tester.tap() doesn't have this problem). Kept in sync by
// hand; every other patrol_test file in this app already duplicates its
// own copies the same way.
Future<void> tapFinder(PatrolIntegrationTester $, Finder finder) async {
  try {
    await $.tester.ensureVisible(finder);
  } catch (_) {
    // Best-effort — see ems_test.dart's tapFinder comment.
  }
  await $.pump(const Duration(milliseconds: 200));
  await $.tester.tap(finder);
  await $.pump(const Duration(milliseconds: 400));
}

Future<void> tapText(PatrolIntegrationTester $, String text) =>
    tapFinder($, find.text(text));

Future<void> tapKey(PatrolIntegrationTester $, String key) =>
    tapFinder($, find.byKey(Key(key)));

/// See ems_test.dart's identical helper for the full rationale.
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
    // Best-effort — see ems_test.dart's tapFinder comment.
  }
  await $.pump(const Duration(milliseconds: 200));
  await $.tester.enterText(finder, text);
  await $.pump(const Duration(milliseconds: 400));
}

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

/// See ems_test.dart's own copy for the full history/rationale of every
/// individual check here — this is a verbatim duplicate, needed because
/// this test denies geolocation the same way ems_test.dart does (turns
/// live tracking off during upload rather than mocking a GPS fix), which
/// means the same in-app "Location permission is off" dialog shows up
/// here too.
Future<void> settleLocationPrompts(PatrolIntegrationTester $) async {
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
          // Best-effort — see ems_test.dart's fuller comment.
        }
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
        // Not present this pass.
      }
    }

    if (find.text('Location permission is off').evaluate().isNotEmpty) {
      handledSomething = true;
      if (kIsWeb) {
        final okButton = find.widgetWithText(TextButton, 'OK');
        if (okButton.evaluate().isNotEmpty) {
          try {
            await tapFinder($, okButton);
          } catch (_) {
            // Retried on the next loop iteration regardless.
          }
        }
      } else {
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

/// See ems_test.dart's identical helper for the full rationale.
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

    // Scoped to this specific patient's own card — same reasoning as
    // ems_test.dart's identical helpers (test-org can have other patients
    // whose cards render the exact same button text).
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

    // No explicit delete here — completing transport already removed this
    // patient from this screen's own active-only list, so there's no
    // card/Delete button left to tap. run-ems-patrol-test.mjs's own
    // cleanup() sweeps any patient whose createdBy uid no longer resolves
    // once this run's throwaway account is deleted, which happens
    // unconditionally after this test, success or failure.
  });
}
