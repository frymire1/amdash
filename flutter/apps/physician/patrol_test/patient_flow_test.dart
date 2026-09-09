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
// intentional feature, not a bug). The patient this test signs in to see
// is created directly via the Firebase Admin SDK, not by this test — pass
// its name/hospital via --dart-define, same convention as EMS's own
// flutter_driver tests.
//
// The account differs by platform, unlike ems_test.dart's equivalent file
// (see that file's own header comment for why EMS *can* safely share one
// account across both, and this one deliberately doesn't): web signs into
// the one persistent physician e2e account (see run-physician-patrol-
// test.mjs's own header comment), always enrolled from a previous run by
// the time this runs, so sign-in goes through the real second-factor
// challenge (signInWithTotp) rather than first-time enrollment. Android
// keeps its own fresh, never-enrolled throwaway account per run instead —
// see this file's own sign-in block for the full reasoning (a real,
// confirmed race, not a hypothetical one, once workLocation enters the
// picture). Phase 0 (web only, below) is a wrong-app rejection using the
// *other* persistent account's email — only works ahead of the real
// sign-in, never after it, since nothing here ever signs out (see
// ems/patrol_test/ems_test.dart's own header comment for the fuller
// reasoning, identical here).
//
// tapFinder/enterTextAt/pumpUntil/signIn/signInWithTotp/
// completeMfaEnrollment come from amdash_patrol_helpers, shared across
// every app's patrol_test/ suite — see that package for the full
// rationale/history behind each one.
import 'package:amdash_patrol_helpers/amdash_patrol_helpers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:patrol/patrol.dart';
import 'package:physician/firebase_options.dart';
import 'package:physician/main.dart';
import 'package:physician/screens/main_view_screen.dart';
import 'package:physician/screens/user_settings_screen.dart';
import 'package:physician/services/patient_alert_service.dart';

void main() {
  patrolTest(
    'rejects the wrong app (web only), signs in, sets work location, and views a patient with a live map',
    ($) async {
      const email = String.fromEnvironment('SMOKE_EMAIL');
      const password = String.fromEnvironment('SMOKE_PASSWORD');
      const hospitalName = String.fromEnvironment('SMOKE_HOSPITAL');
      const patientName = String.fromEnvironment(
        'SMOKE_PATIENT_NAME',
        defaultValue: 'Physician Verify Patient',
      );
      // Both only actually read on the kIsWeb branches below — Android
      // signs into a different, throwaway account that's never enrolled
      // ahead of time and never attempts the wrong-app phase at all (see
      // this file's own sign-in comment for why the two platforms
      // diverge), so its own build doesn't need real values for either.
      const totpSecret = String.fromEnvironment('SMOKE_TOTP_SECRET');
      const wrongAppEmail = String.fromEnvironment('WRONG_APP_EMAIL');
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

      // ---- Phase 0 (web only): an ems-role account is rejected at
      // physician's own login screen. See ems_test.dart's identical phase
      // for the fuller comment — same reasoning, mirrored here with the
      // roles swapped. ----
      if (kIsWeb) {
        expect(wrongAppEmail, isNotEmpty, reason: 'pass --dart-define=WRONG_APP_EMAIL=...');
        await enterTextAt($, 0, wrongAppEmail);
        await tapText($, 'Continue');
        await pumpUntil(
          $,
          () => find.text('Access denied').evaluate().isNotEmpty,
          maxIterations: 40,
        );
        expect(find.text('Access denied'), findsOneWidget);
        expect(
          find.textContaining("doesn't have access to the AmDash — Physician app"),
          findsOneWidget,
        );
        expect(
          find.byType(MainViewScreen),
          findsNothing,
          reason: 'must never reach the real physician main view',
        );
        expect(find.text('EMS app'), findsOneWidget);
        expect(find.text('Physician app'), findsNothing);
        await tapText($, 'Use a different email');
        await pumpUntil(
          $,
          () => find.text('Access denied').evaluate().isEmpty,
          maxIterations: 40,
        );
      }

      // ---- Sign in for real. ----
      //
      // Platform-gated, unlike ems_test.dart's identical-looking call:
      // physician's own default patient-list filter defaults to
      // profile.workLocation (see patient_list.dart), a single mutable
      // field — sharing one persistent account between this file's own
      // web run and the *concurrently-running* flutter-android-e2e job's
      // own run of this same file would mean each one's workLocation
      // write could race the other's read, with no way to tell which
      // wrote last (confirmed as a real risk, not hypothetical, once this
      // file started sharing an account across scenarios at all — EMS has
      // no such shared single-value state, which is why ems_test.dart
      // *can* safely use one persistent account on both platforms). Web
      // uses the persistent, already-enrolled account (signInWithTotp);
      // Android keeps its own fresh, never-enrolled throwaway account per
      // run (signIn + completeMfaEnrollment, the original mechanism) —
      // see run-physician-patrol-test.mjs's own header comment.
      if (kIsWeb) {
        expect(totpSecret, isNotEmpty, reason: 'pass --dart-define=SMOKE_TOTP_SECRET=...');
        await signInWithTotp($, email, password, totpSecret);
      } else {
        await signIn($, email, password);
        await completeMfaEnrollment($);
      }

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

      // Web only: explicitly select this run's own hospital in
      // PatientList's own destination filter, rather than relying on its
      // *default* selection (which comes from profile.workLocation — see
      // patient_list.dart). That default is exactly right for a
      // throwaway, single-use account (Android's own leg — see this
      // file's own sign-in comment for why it keeps a fresh one), but web
      // signs into the shared persistent physician account, which has no
      // guarantee this exact hospital was the *last* one written to
      // workLocation by some earlier run of this same script, since
      // nothing resets it between runs. Driving the real Filter UI
      // instead makes this assertion depend only on what this run itself
      // just selected, not on whatever workLocation happened to already
      // be.
      //
      // Confirmed for real why this can't *also* run on Android
      // unconditionally: the dropdown this opens overflowed by 23px on
      // Test Lab's own MediumPhone device width (a real RenderFlex
      // overflow at that screen size, in patient_list.dart's own
      // DropdownButtonFormField — not present on web's wider default
      // viewport), crashing the whole test. Android's own throwaway
      // account never needs this in the first place (its workLocation is
      // always freshly set, this same run, by the picker step above), so
      // gating it here costs nothing real.
      if (kIsWeb) {
        await tapFinder($, find.byTooltip('Filter'));
        await pumpUntil(
          $,
          () => find.byType(DropdownButtonFormField<String>).evaluate().isNotEmpty,
          maxIterations: 20,
        );
        await tapFinder($, find.byType(DropdownButtonFormField<String>));
        await pumpUntil(
          $,
          () => find.text(hospitalName).evaluate().length > 1,
          maxIterations: 20,
        );
        // Same lazy-finder-race reasoning as the hospital-autocomplete tap
        // above — no `await` between computing the index and tapping it.
        final destinationMatches = find.text(hospitalName);
        await $.tester.tap(
          destinationMatches.at(destinationMatches.evaluate().length - 1),
        );
        await $.pump(const Duration(milliseconds: 400));
      }

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

      // ---- Patient-arrival proximity alerts: drive the *real* Enable
      // button, on Android only. ----
      //
      // This same file also runs on Chrome — scripts/
      // run-physician-patrol-test.mjs's own self-contained (no --seed-
      // only/--android) mode defaults to `device: 'chrome'` and targets
      // this exact file, alongside the separate `patrol build android` +
      // Test Lab job (see ci.yml's flutter-android-e2e-physician). A
      // first version of this phase ran unconditionally and broke that
      // Chrome job for the same reason incoming_patient_test.dart's own
      // web counterpart never drives this button either: Patrol's bundled
      // Playwright Chromium can't complete a real FCM push registration
      // (confirmed for real, twice now: `debugLastEnableAlertsError`
      // reporting `AbortError: Registration failed - permission denied`,
      // a known Playwright/Chromium push-registration limitation, not an
      // app bug — see incoming_patient_test.dart's own comment). Android
      // Test Lab's device runs real Google Play Services, so the real
      // requestPermission() -> getToken() round trip can complete for
      // real there — gating on kIsWeb (true only for the Chrome job) is
      // what lets this phase exist at all without breaking that sibling
      // job, and is the whole reason this phase is worth having: proving
      // the production FCM path actually works somewhere in this suite,
      // not just that the checkbox persists.
      //
      // Unlike incoming_patient_test.dart's account (pre-seeded with
      // etaAlertThresholdsMinutes: [30] by run-patient-flow-e2e.mjs), this
      // one (scripts/run-physician-patrol-test.mjs) seeds no alert
      // preferences at all — the checkbox starts unchecked, so this
      // actually checks it rather than just confirming a prefill.
      if (!kIsWeb) {
        await tapFinder($, find.byTooltip('Account'));
        await pumpUntil($, () => find.text('Settings').evaluate().isNotEmpty);
        await tapText($, 'Settings');
        await pumpUntil(
          $,
          () => find.byType(UserSettingsScreen).evaluate().isNotEmpty,
        );

        final thirtyMinuteBox = find.byKey(const Key('eta_threshold_30'));
        await pumpUntil($, () => thirtyMinuteBox.evaluate().isNotEmpty);
        await tapFinder($, thirtyMinuteBox);

        await tapText($, 'Enable');
        await pumpUntil(
          $,
          () => find.textContaining('Alerts armed until').evaluate().isNotEmpty,
          maxIterations: 60,
        );

        // TOO_MANY_REGISTRATIONS is FCM's own registration rate limit on
        // the Test Lab device, not an app bug — confirmed for real (this
        // exact error, on this exact phase, on a day with an unusually
        // high number of back-to-back CI runs each making a genuine
        // getToken() call against the same reused device). Every other
        // debugLastEnableAlertsError value still hard-fails below — this
        // carve-out is narrow on purpose, so a real regression (a token-
        // parsing bug, a permission problem, anything else) still fails
        // the way it always did.
        final error = debugLastEnableAlertsError;
        final hitFcmRegistrationQuota =
            error is FirebaseException && error.code == 'unknown' && (error.message ?? '').contains('TOO_MANY_REGISTRATIONS');
        if (hitFcmRegistrationQuota) {
          debugPrint('Skipping the Enable-alerts assertion: hit FCM\'s own TOO_MANY_REGISTRATIONS '
              'registration rate limit on this Test Lab device (a known, transient Google-side '
              'quota, not an app bug) — $error');
        } else {
          expect(
            find.textContaining('Alerts armed until'),
            findsOneWidget,
            reason:
                'the real Enable button, permission grant, and FCM getToken() round trip should all '
                'succeed on Android (unlike Patrol\'s Playwright-backed web runner) — '
                'debugLastEnableAlertsError: $debugLastEnableAlertsError',
          );
        }
      }
    },
  );
}
