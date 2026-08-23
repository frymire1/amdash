// Cross-app verification (see scripts/run-patient-flow-e2e.mjs, which
// orchestrates this alongside ems's patient_upload_flow_test.dart, run
// first): signs in as a physician whose workLocation is pre-seeded to
// match the hospital ems's test just uploaded a patient for, and confirms
// that real patient — not one seeded directly via the Admin SDK, like
// patient_flow_test.dart uses — actually shows up with a live map
// centered on the exact (mocked) GPS coordinates ems's test used, and
// that vitals reflect ems's own later edit (also real, done through the
// EMS app's own UI), not just the original upload. This is the actual
// point of the whole two-app flow: proving an upload *and* a later
// update on one app are genuinely what physician sees, not two tests
// independently exercising their own UI against synthetic state.
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:otp/otp.dart';
import 'package:patrol/patrol.dart';
import 'package:physician/firebase_options.dart';
import 'package:physician/main.dart';
import 'package:physician/screens/main_view_screen.dart';

// See patient_flow_test.dart's fuller comment on why this app's Patrol
// tests use raw WidgetTester taps instead of Patrol's own $(...).tap().
Future<void> tapFinder(PatrolIntegrationTester $, Finder finder) async {
  await $.tester.ensureVisible(finder);
  await $.pump(const Duration(milliseconds: 200));
  await $.tester.tap(finder);
  await $.pump(const Duration(milliseconds: 400));
}

Future<void> tapText(PatrolIntegrationTester $, String text) =>
    tapFinder($, find.text(text));

/// Polls with fixed pumps rather than a one-shot wait — see
/// patient_flow_test.dart's equivalent helper, which this mirrors.
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

/// See patient_flow_test.dart's equivalent for the full rationale (no
/// server-side shortcut exists for TOTP; this drives the real enrollment
/// UI).
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
  patrolTest(
    "physician sees ems's uploaded patient with a live map at the mocked GPS fix",
    ($) async {
      const email = String.fromEnvironment('SMOKE_EMAIL');
      const password = String.fromEnvironment('SMOKE_PASSWORD');
      const patientName = String.fromEnvironment('SMOKE_PATIENT_NAME');
      // There's no double.fromEnvironment (only int/bool/String) — read as
      // a string const-define and parse at runtime instead.
      const latitudeStr = String.fromEnvironment('SMOKE_LATITUDE');
      const longitudeStr = String.fromEnvironment('SMOKE_LONGITUDE');
      final latitude = double.tryParse(latitudeStr) ?? 0.0;
      final longitude = double.tryParse(longitudeStr) ?? 0.0;
      expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
      expect(
        password,
        isNotEmpty,
        reason: 'pass --dart-define=SMOKE_PASSWORD=...',
      );
      expect(
        patientName,
        isNotEmpty,
        reason: 'pass --dart-define=SMOKE_PATIENT_NAME=...',
      );
      // A real (0, 0) coordinate is implausible for this app's
      // Toronto-area test data, so unparsed/missing SMOKE_LATITUDE/
      // SMOKE_LONGITUDE reliably shows up here instead of silently
      // asserting against "Live position: 0.0000, 0.0000" later.
      expect(
        latitude,
        isNot(0.0),
        reason: 'pass --dart-define=SMOKE_LATITUDE=...',
      );
      expect(
        longitude,
        isNot(0.0),
        reason: 'pass --dart-define=SMOKE_LONGITUDE=...',
      );
      // Fixed literal matching patient_upload_flow_test.dart's own
      // constant of the same name — see that file's comment on why it
      // doesn't need to be a dart-define. Its counterpart
      // initialHeartRate isn't needed here: this test only confirms the
      // trend dialog actually charts data (proving a second history
      // entry exists), not the specific pre-edit value.
      const updatedHeartRate = '92';

      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      await $.pumpWidgetAndSettle(const ProviderScope(child: PhysicianApp()));

      // Sign in. No work-location step here — this account's workLocation
      // is pre-seeded by the orchestrator to match the hospital ems's test
      // uploaded for, unlike patient_flow_test.dart which drives that
      // screen itself.
      await $(TextField).at(0).enterText(email);
      await tapText($, 'Continue');
      await pumpUntil($, () => find.text('Sign In').evaluate().isNotEmpty);
      await $(TextField).at(0).enterText(password);
      await tapText($, 'Sign In');

      await completeMfaEnrollment($);

      await pumpUntil(
        $,
        () => find.byType(MainViewScreen).evaluate().isNotEmpty,
        maxIterations: 100,
      );

      // The patient ems's test just uploaded through its own UI — not
      // seeded by this script — should already be in the list, filtered
      // to this destination by default (see PatientList's own doc
      // comment: defaults to the physician's workLocation).
      await pumpUntil(
        $,
        () => find.text(patientName).evaluate().isNotEmpty,
        maxIterations: 60,
      );
      // Tapped directly, not via tapFinder — a real GHA "Bad state: No
      // element" hit this exact pattern in patient_flow_test.dart's own
      // equivalent tap: .first is a lazy, re-evaluating finder, and
      // tapFinder's ensureVisible + 200ms pump gave the live patient-list
      // snapshot listener a real window to rebuild before the actual tap
      // re-evaluated it.
      await $.tester.tap(find.text(patientName).first);
      await $.pump(const Duration(milliseconds: 400));

      await pumpUntil(
        $,
        () => find.text('Destination Hospital').evaluate().isNotEmpty,
      );
      await pumpUntil($, () => find.byType(GoogleMap).evaluate().isNotEmpty);
      expect(
        $(GoogleMap),
        findsOneWidget,
        reason: 'patient has a live GPS fix, so the map should render',
      );

      // The strong check: not just that a map exists, but that its
      // vehicle marker is positioned at the exact coordinates ems's test
      // mocked via --web-geolocation. Reads the Marker's own position
      // property directly rather than matching the "Live position: ..."
      // caption text (patient_viewer.dart only shows that caption once
      // EmsTrackingStatus reaches active — a brand new fix can still read
      // as stale for a moment, well before the caption's own 35s
      // staleness budget is at risk, and the marker itself renders
      // regardless of that distinction either way).
      final markers = $.tester
          .widget<GoogleMap>(find.byType(GoogleMap))
          .markers;
      final vehicleMarker = markers.firstWhere(
        (marker) => marker.markerId == const MarkerId('vehicle'),
        orElse: () => throw StateError(
          'No "vehicle" marker on the map — expected one from a live GPS fix.',
        ),
      );
      expect(
        vehicleMarker.position.latitude,
        closeTo(latitude, 0.0001),
        reason:
            "the map's vehicle marker should reflect ems's mocked GPS fix exactly, not a stale or default position",
      );
      expect(
        vehicleMarker.position.longitude,
        closeTo(longitude, 0.0001),
        reason:
            "the map's vehicle marker should reflect ems's mocked GPS fix exactly, not a stale or default position",
      );

      // The vitals card always shows the patient's current vitals (see
      // patient_viewer.dart's _vitalsCard) — ems's edit ran after the
      // initial upload, so this should already be the edited value, not
      // the original one, proving the edit (not just the upload) is what
      // physician actually sees.
      await pumpUntil(
        $,
        () => find.text('$updatedHeartRate bpm').evaluate().isNotEmpty,
        maxIterations: 40,
      );
      expect(
        find.text('$updatedHeartRate bpm'),
        findsOneWidget,
        reason:
            "vital signs should default to ems's edited heart rate, not the original upload",
      );

      // Vitals history browsing now happens through the per-vital trend
      // chart icon rather than dedicated back/forward arrows (see
      // patient_viewer.dart's _vitalsCard/_infoRow) — opening Heart
      // Rate's trend dialog and confirming it actually rendered a chart,
      // not the "not enough data" placeholder that shows for a single
      // reading, proves the edit appended a new vitalsHistory entry
      // rather than overwriting the only one.
      final heartRateTrendIcon = find.byKey(
        const Key('vitals_trend_Heart Rate'),
      );
      // vitalsHistoryProvider is a one-time fetch (not a live listener —
      // see its own doc comment), so the icon only appears once that
      // fetch resolves; wait for it rather than assuming it's already
      // there on the first frame this card renders.
      await pumpUntil($, () => heartRateTrendIcon.evaluate().isNotEmpty);
      await tapFinder($, heartRateTrendIcon);
      await pumpUntil($, () => find.byType(AlertDialog).evaluate().isNotEmpty);
      expect(
        find.text('Not enough recorded data yet to show a trend.'),
        findsNothing,
        reason:
            "the trend dialog should chart ems's original upload and later edit as two points, not report insufficient data",
      );
      await tapText($, 'Close');
    },
  );
}
