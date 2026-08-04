// Phase 2 verification: runs via `patrol test --device chrome` against real
// Chrome (through Patrol's Playwright-backed web runner), real Firebase
// Auth/Firestore on amdash-dev, and (with a real Maps/Directions API key
// passed via --dart-define=DIRECTIONS_API_KEY=...) the real Google Maps JS
// API. Unlike the raw flutter_driver/integration_test approach this
// replaced, Patrol's `$` finder actions (tap/enterText/waitUntilVisible)
// use a bounded `trySettle` policy (10s default) rather than
// pumpAndSettle()'s "wait for zero pending frames" — which would otherwise
// hang for its full 10-minute timeout once MainViewScreen's permanent 5s
// EmsLocationService staleness-sweep Timer starts firing (a real,
// intentional feature, not a bug). The throwaway account and the patient
// it signs in to see are both created directly via the Firebase Admin
// SDK, not by this test — pass the account's email/password via
// --dart-define, same convention as EMS's own flutter_driver tests.
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:patrol/patrol.dart';
import 'package:physician/firebase_options.dart';
import 'package:physician/main.dart';
import 'package:physician/screens/main_view_screen.dart';

// Patrol's own `.tap()` requires a widget to pass its hit-testable check,
// which — verified manually against a real browser, where every one of
// these interactions works fine — proved unreliable against this app's
// Material overlays (the hospital autocomplete's option list) on Flutter
// Web/CanvasKit through Patrol's Playwright-backed web runner. Raw
// $.tester.tap() (only requires the widget to exist, then simulates the
// tap at its computed center) doesn't have this problem; see the admin
// app's patrol_test/user_flow_test.dart for the same fix applied there.
Future<void> tapFinder(PatrolIntegrationTester $, Finder finder) async {
  await $.tester.ensureVisible(finder);
  await $.pump(const Duration(milliseconds: 200));
  await $.tester.tap(finder);
  await $.pump(const Duration(milliseconds: 400));
}

Future<void> tapText(PatrolIntegrationTester $, String text) => tapFinder($, find.text(text));

void main() {
  patrolTest(
    'signs in, sets work location, and views a patient with a live map',
    ($) async {
      const email = String.fromEnvironment('SMOKE_EMAIL');
      const password = String.fromEnvironment('SMOKE_PASSWORD');
      const hospitalName = String.fromEnvironment('SMOKE_HOSPITAL');
      const patientName = String.fromEnvironment('SMOKE_PATIENT_NAME', defaultValue: 'Physician Verify Patient');
      expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
      expect(password, isNotEmpty, reason: 'pass --dart-define=SMOKE_PASSWORD=...');
      expect(hospitalName, isNotEmpty, reason: 'pass --dart-define=SMOKE_HOSPITAL=...');

      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      await $.pumpWidgetAndSettle(const ProviderScope(child: PhysicianApp()));

      // Sign in.
      await $(TextField).at(0).enterText(email);
      await tapText($, 'Continue');

      await $('Sign In').waitUntilVisible();
      await $(TextField).at(0).enterText(password);
      await tapText($, 'Sign In');

      // Work location — only asked once; skip if this account already has
      // one from a previous run.
      await $.pump(const Duration(seconds: 2));
      if ($('Select Your Hospital').exists) {
        await $(TextField).at(0).enterText(hospitalName);
        await $(hospitalName).waitUntilVisible();
        // The autocomplete overlay renders the option in its own overlay
        // route — the last match is the option, not the field's own text.
        await tapFinder($, find.text(hospitalName).at(find.text(hospitalName).evaluate().length - 1));
        // The Autocomplete's options overlay stays mounted (a full-screen
        // AbsorbPointer, confirmed via --show-flutter-logs's hit-test
        // warning) as long as the field keeps focus and its query still
        // has a match — which it does here, since the field's text
        // already equals the selected option. A real click elsewhere
        // normally unfocuses the field as a side effect and closes it,
        // but a raw synthetic tap doesn't carry that browser-level focus
        // semantics (confirmed: tapping the screen title first didn't
        // help either — the very next tap on 'Continue' still got
        // silently absorbed instead of reaching the button). Force the
        // unfocus directly instead of relying on tap-outside-to-dismiss.
        FocusManager.instance.primaryFocus?.unfocus();
        await $.pump(const Duration(milliseconds: 300));
        await tapText($, 'Continue');
      }

      // Self-heals a cache-flicker bounce back to /work-location, thanks
      // to the reactive guard fix — just needs enough time to settle.
      await $(MainViewScreen).waitUntilVisible(timeout: const Duration(seconds: 20));

      // The seeded patient should appear in the list.
      await $(patientName).waitUntilVisible(timeout: const Duration(seconds: 15));
      await tapFinder($, find.text(patientName).first);

      // Patient viewer should now show this patient's info/vitals, and a
      // real Google Map for its uploaded pickup location.
      await $('Destination Hospital').waitUntilVisible();
      expect($('Vital Signs'), findsOneWidget);
      expect($(GoogleMap), findsOneWidget, reason: 'patient has a location, so the map should render');
    },
  );
}
