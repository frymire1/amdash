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
      await $('Continue').tap();

      await $('Sign In').waitUntilVisible();
      await $(TextField).at(0).enterText(password);
      await $('Sign In').tap();

      // Work location — only asked once; skip if this account already has
      // one from a previous run.
      await $.pump(const Duration(seconds: 2));
      if ($('Select Your Hospital').exists) {
        await $(TextField).at(0).enterText(hospitalName);
        await $(hospitalName).waitUntilVisible();
        // The autocomplete overlay renders the option in its own overlay
        // route — the last match is the option, not the field's own text.
        await $(hospitalName).at($(hospitalName).evaluate().length - 1).tap();
        await $('Continue').tap();
      }

      // Self-heals a cache-flicker bounce back to /work-location, thanks
      // to the reactive guard fix — just needs enough time to settle.
      await $(MainViewScreen).waitUntilVisible(timeout: const Duration(seconds: 20));

      // The seeded patient should appear in the list.
      await $(patientName).waitUntilVisible(timeout: const Duration(seconds: 15));
      await $(patientName).at(0).tap();

      // Patient viewer should now show this patient's info/vitals, and a
      // real Google Map for its uploaded pickup location.
      await $('Patient Information').waitUntilVisible();
      expect($('Vital Signs'), findsOneWidget);
      expect($(GoogleMap), findsOneWidget, reason: 'patient has a location, so the map should render');
    },
  );
}
