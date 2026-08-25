// Cross-app verification (see scripts/run-patient-flow-e2e.mjs, which
// orchestrates this alongside physician's incoming_patient_test.dart):
// uploads a patient with live tracking enabled and a real destination
// hospital selected, confirming it appears on this app's own dashboard.
// The actual point of this test is what it leaves behind in Firestore —
// physician's half of the flow checks that a real EMS upload (not an
// Admin SDK-seeded patient, like patient_flow_test.dart uses) is what
// makes a patient visible there. GPS is mocked via Playwright's
// geolocation override (--web-geolocation, passed by the orchestrator),
// not a real device fix — see run-patrol.mjs's webGeolocation param.
// Deliberately no self-cleanup here (unlike complete_and_export_test.dart)
// — the whole point is the patient this test uploads/edits stays behind
// for incoming_patient_test.dart to find; run-patient-flow-e2e.mjs's own
// orchestration owns tearing it down once both halves are done.
//
// tapFinder/enterTextAt/pumpUntil/dismissNativeLocationAccuracyDialog/
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
  patrolTest('EMS uploads a live-tracked patient bound for a real hospital', (
    $,
  ) async {
    const email = String.fromEnvironment('SMOKE_EMAIL');
    const password = String.fromEnvironment('SMOKE_PASSWORD');
    const hospitalName = String.fromEnvironment('SMOKE_HOSPITAL');
    const patientName = String.fromEnvironment('SMOKE_PATIENT_NAME');
    expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
    expect(
      password,
      isNotEmpty,
      reason: 'pass --dart-define=SMOKE_PASSWORD=...',
    );
    expect(
      hospitalName,
      isNotEmpty,
      reason: 'pass --dart-define=SMOKE_HOSPITAL=...',
    );
    expect(
      patientName,
      isNotEmpty,
      reason: 'pass --dart-define=SMOKE_PATIENT_NAME=...',
    );
    // Fixed literals, not dart-defines — unlike email/password/hospital/
    // patient name, these don't need to be unique per run (no collision
    // risk), so there's nothing an orchestrator needs to generate or
    // thread through. incoming_patient_test.dart hardcodes the same two
    // values for its own assertions.
    const initialHeartRate = '88';
    const updatedHeartRate = '92';

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

    await pumpUntil(
      $,
      () => find.byType(HomeScreen).evaluate().isNotEmpty,
      maxIterations: 50,
    );

    // Add a patient. Fields, by index: 0=Name, 1=Age, 2=Healthcare Number,
    // 3=Heart Rate (Gender/Destination Hospital are dropdowns, not
    // TextFields) — see ems_test.dart.
    await tapText($, 'Add Patient');
    await pumpUntil(
      $,
      () => find.byType(PatientUploadScreen).evaluate().isNotEmpty,
    );
    await dismissNativeLocationAccuracyDialog($);
    await enterTextAt($, 0, patientName);
    await enterTextAt($, 2, 'TEST-12345');
    await enterTextAt($, 3, initialHeartRate);

    // Unlike ems_test.dart, this test needs a real destination selected
    // (physician's own patient list filters by it) and live tracking left
    // ON (default) — the whole point here is exercising the GPS path
    // ems_test.dart deliberately turns off.
    await tapKey($, 'patient_destination_dropdown');
    await tapKey($, 'patient_destination_option_$hospitalName');

    // Confirms the mocked geolocation actually resolved through
    // Geolocator.getCurrentPosition() before submitting — if
    // --web-geolocation/--web-permissions weren't wired through
    // correctly, this never turns "Tracking Active" and the test fails
    // here with a clear signal, not a confusing later assertion.
    await pumpUntil(
      $,
      () => find.text('Tracking Active').evaluate().isNotEmpty,
      maxIterations: 40,
    );

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

    // Now edit it — physician's half of this flow (incoming_patient_test.dart)
    // checks that this real edit, not just the initial upload, is what it
    // sees. Scoped to this specific patient's own card, same reasoning as
    // ems_test.dart's equivalent helper: not by button text alone, since
    // test-org can have other patients whose cards render the exact same
    // "Edit" text.
    Finder cardButtonFor(String name, String buttonLabel) => find.descendant(
      of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
      matching: find.widgetWithText(OutlinedButton, buttonLabel),
    );
    final editButton = cardButtonFor(patientName, 'Edit');
    await pumpUntil(
      $,
      () => editButton.evaluate().isNotEmpty,
      maxIterations: 30,
    );
    await tapFinder($, editButton);

    await pumpUntil(
      $,
      () => find.byType(PatientUploadScreen).evaluate().isNotEmpty,
    );
    // Wait for the async prefill (reads the uploaded-patients list) to
    // land before touching a field, or a fast enterText can race it and
    // get silently overwritten a moment later — see ems_test.dart's
    // equivalent comment.
    await pumpUntil(
      $,
      () => find.text(patientName).evaluate().isNotEmpty,
      maxIterations: 40,
    );
    await dismissNativeLocationAccuracyDialog($);
    // The location section re-fetches from scratch on every mount, even in
    // edit mode — wait for it to resolve back to "Tracking Active" before
    // touching Save. Same class of race ems_test.dart's own edit flow hit
    // for real on GHA (there, the transition is to a much longer error
    // message that wraps a line and visibly shifts the Save button; here
    // it's "Locating…" -> "Tracking Active", a smaller shift, but cheap
    // insurance against the same stale-offset-tap failure mode).
    await pumpUntil(
      $,
      () => find.text('Tracking Active').evaluate().isNotEmpty,
      maxIterations: 40,
    );
    await enterTextAt($, 3, updatedHeartRate);
    await tapKey($, 'patient_upload_submit');
    await pumpUntil(
      $,
      () => find.text('$updatedHeartRate bpm').evaluate().isNotEmpty,
      maxIterations: 40,
    );
    expect(
      find.text('$updatedHeartRate bpm'),
      findsOneWidget,
      reason: 'edited heart rate should show on the home screen',
    );
  });
}
