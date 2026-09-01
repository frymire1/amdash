// Phase 2 verification: runs via `patrol test --device chrome` against real
// Chrome (through Patrol's Playwright-backed web runner), real Firebase
// Auth/Firestore on amdash-dev, and the real Google Maps JS API (Directions
// data comes from the `fetchDirections` Cloud Function, not a client-side
// key). Unlike the raw flutter_driver/integration_test approach this
// replaced, Patrol's `$` finder actions (tap/enterText/waitUntilVisible)
// use a bounded `trySettle` policy (10s default) rather than
// pumpAndSettle()'s "wait for zero pending frames" — which would otherwise
// hang for its full 10-minute timeout once MainViewScreen's permanent 5s
// EmsLocationService staleness-sweep Timer starts firing (a real,
// intentional feature, not a bug). The throwaway account and the patient
// it signs in to see are both created directly via the Firebase Admin
// SDK, not by this test — pass the account's email/password via
// --dart-define, same convention as EMS's own flutter_driver tests.
//
// tapFinder/enterTextAt/pumpUntil/completeMfaEnrollment come from
// amdash_patrol_helpers, shared across every app's patrol_test/ suite —
// see that package for the full rationale/history behind each one.
import 'package:amdash_patrol_helpers/amdash_patrol_helpers.dart';
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
      const patientName = String.fromEnvironment(
        'SMOKE_PATIENT_NAME',
        defaultValue: 'Physician Verify Patient',
      );
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

      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      await $.pumpWidgetAndSettle(const ProviderScope(child: PhysicianApp()));

      // Sign in.
      await enterTextAt($, 0, email);
      await tapText($, 'Continue');

      await pumpUntil($, () => find.text('Sign In').evaluate().isNotEmpty);
      await enterTextAt($, 0, password);
      await tapText($, 'Sign In');

      await completeMfaEnrollment($);

      // Work location — only asked once; skip if this account already has
      // one from a previous run.
      await $.pump(const Duration(seconds: 2));
      if ($('Select Your Hospital').exists) {
        await enterTextAt($, 0, hospitalName);
        await pumpUntil($, () => find.text(hospitalName).evaluate().isNotEmpty);
        // The autocomplete overlay renders the option in its own overlay
        // route — the last match is the option, not the field's own text.
        // Tapped directly here, not via tapFinder — that helper's own
        // ensureVisible + 200ms pump between receiving this finder and
        // actually tapping it left a real window for the overlay to
        // collapse first (confirmed via a real GHA "Bad state: No
        // element": `.at(index)` is a *lazy*, re-evaluating finder, and by
        // tap time the match count had already dropped from 2 back to 1,
        // making the precomputed index out of bounds). No `await` between
        // computing the index and tapping it here, so there's no
        // opportunity for a rebuild to shrink the match count in between.
        final hospitalMatches = find.text(hospitalName);
        await $.tester.tap(
          hospitalMatches.at(hospitalMatches.evaluate().length - 1),
        );
        await $.pump(const Duration(milliseconds: 400));
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
      // Was $(MainViewScreen).waitUntilVisible(...), bumped from 20s to
      // 40s once already, but still timed out — confirmed via a real GHA
      // run's own Playwright accessibility snapshot that the screen was
      // actually fully rendered and interactive (patient list, patient
      // card, everything) at the moment it "failed". That's Patrol's own
      // hit-test check being unreliable here, the same class of flakiness
      // tapFinder's comment above already documents for taps — pumpUntil
      // + find.byType().evaluate() (existence, not hit-testability) is
      // the proven fix throughout this codebase (see admin's
      // user_flow_test.dart, which relies on it exclusively and passes
      // reliably).
      await pumpUntil(
        $,
        () => find.byType(MainViewScreen).evaluate().isNotEmpty,
        maxIterations: 100,
      );

      // The seeded patient should appear in the list.
      await pumpUntil(
        $,
        () => find.text(patientName).evaluate().isNotEmpty,
        maxIterations: 40,
      );
      // Tapped directly, not via tapFinder — see the hospital-autocomplete
      // tap above for the full rationale (a real GHA "Bad state: No
      // element" hit here too, same root cause: .first is a lazy,
      // re-evaluating finder, and tapFinder's ensureVisible + 200ms pump
      // gave the live patient-list snapshot listener a real window to
      // rebuild before the actual tap re-evaluated it).
      await $.tester.tap(find.text(patientName).first);
      await $.pump(const Duration(milliseconds: 400));

      // Patient viewer should now show this patient's info/vitals, and a
      // real Google Map for its uploaded pickup location.
      await pumpUntil(
        $,
        // 'Destination' — see incoming_patient_test.dart's identical wait
        // for why this isn't 'Destination Hospital' anymore.
        () => find.text('Destination').evaluate().isNotEmpty,
      );
      expect($('Vital Signs'), findsOneWidget);
      // GoogleMap has its own async load on top of 'Destination' rendering
      // (the Maps JS API script + tiles, not just the surrounding Flutter
      // widget tree) — a bare check right after 'Destination' appears races
      // that load under CI network conditions. Confirmed for real: this
      // failed "Found 0 widgets with type GoogleMap" 3 times in a row
      // across otherwise-unrelated CI runs on 2026-08-31, always at this
      // exact assertion — the same unpolled-immediate-check anti-pattern
      // already fixed elsewhere in this suite (see MainViewScreen's own
      // self-heal comment just above), not incidental flakiness.
      final googleMap = find.byType(GoogleMap);
      await pumpUntil($, () => googleMap.evaluate().isNotEmpty, maxIterations: 40);
      expect(
        googleMap,
        findsOneWidget,
        reason: 'patient has a location, so the map should render',
      );
    },
  );
}
