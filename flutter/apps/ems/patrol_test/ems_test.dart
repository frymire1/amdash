// Phase 5-ish verification (added after Phases 1-4): runs via `patrol test
// --device chrome` against real Chrome, real Firebase Auth/Firestore on
// amdash-dev (and, unlike originally, also against real Android via
// Firebase Test Lab — see the kIsWeb gating below). Unlike physician/
// admin's Patrol tests, this one creates, edits, and deletes its own
// throwaway patient entirely through the app's own UI — the runner script
// only needs to point it at a real EMS account (see
// scripts/run-ems-patrol-test.mjs).
//
// Three phases, one `patrolTest` block, one continuous execution with no
// reload in the middle at any point — the whole reason any of this can
// share one process/browser tab at all (Patrol's own native test
// dispatcher does a full page reload *between* separate `patrolTest`
// blocks, confirmed for real: a second block's fresh `pumpWidgetAndSettle`
// landed back on LoginScreen even though an earlier block had just signed
// in, so nothing about session state carries across a block boundary —
// see amdash_patrol_helpers' session.dart for the fuller account of that
// finding). Patrol reports this as one named result, not three — a real
// trade-off versus separate pass/fail per scenario, accepted here since a
// failure's own exception/stack trace still says which phase broke.
//
// Phase 0 (web only) uses a *different* account than phases 1-2 — the
// persistent physician account, attempting to sign into EMS and getting
// rejected — which only works ahead of phase 1's own sign-in, never after
// it: nothing here ever signs out (there's no working way to, mid-test —
// see session.dart again), so once phase 1 signs in for real, the session
// can only ever be that one account from then on. Phases 1-2 both reuse
// that one persistent EMS account (and its one MFA enrollment) rather
// than a fresh throwaway one — this account is deliberately never torn
// down between runs; see scripts/run-ems-patrol-test.mjs's own header
// comment for the full reasoning and how its TOTP secret is supplied.
//
// signInWithTotp/tapFinder/enterTextAt/pumpUntil/settleLocationPrompts
// come from amdash_patrol_helpers, shared across every app's patrol_test/
// suite — see that package for the full rationale/history behind each
// one.
import 'package:amdash_core/amdash_core.dart';
import 'package:amdash_patrol_helpers/amdash_patrol_helpers.dart';
import 'package:ems/firebase_options.dart';
import 'package:ems/main.dart';
import 'package:ems/screens/home_screen.dart';
import 'package:ems/screens/patient_upload_screen.dart';
import 'package:ems/services/patient_upload_service.dart';
import 'package:ems/widgets/patient_summary_card.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

void main() {
  patrolTest(
    'rejects the wrong app (web only), signs in, adds/edits/deletes a patient, then completes transport and exports a FHIR record',
    ($) async {
      const email = String.fromEnvironment('SMOKE_EMAIL');
      const password = String.fromEnvironment('SMOKE_PASSWORD');
      const totpSecret = String.fromEnvironment('SMOKE_TOTP_SECRET');
      // Only actually read on the kIsWeb branch below — Android's own
      // flutter-android-e2e build still has to pass *something* for every
      // dart-define this file declares, but doesn't need a real value
      // (see ci.yml's own android build step, which passes an empty
      // string here on purpose).
      const wrongAppEmail = String.fromEnvironment('WRONG_APP_EMAIL');
      expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
      expect(
        password,
        isNotEmpty,
        reason: 'pass --dart-define=SMOKE_PASSWORD=...',
      );
      expect(
        totpSecret,
        isNotEmpty,
        reason: 'pass --dart-define=SMOKE_TOTP_SECRET=...',
      );

      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      await $.pumpWidgetAndSettle(const ProviderScope(child: EmsApp()));

      // ---- Phase 0 (web only): a physician-role account is rejected at
      // EMS's own login screen. ---
      //
      // Not run on Android: nothing about "enter email, tap Continue, wait
      // for 'Access denied' text, assert the right app link shows" is
      // platform-specific (see wrong_app_login_test.dart's own git
      // history — this used to be that file, folded in here once it
      // became clear its own real cost was a redundant account+process,
      // not anything this phase itself needed Android for), and Android's
      // own flutter-android-e2e job already runs this exact file for
      // phases 1-2 — adding this phase there too would just be a second,
      // pointless account-switch attempt with no working way to get back
      // to a clean LoginScreen afterward (see this file's own header
      // comment on why nothing here ever signs out).
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
          find.textContaining("doesn't have access to the AmDash — EMS app"),
          findsOneWidget,
        );
        expect(
          find.byType(HomeScreen),
          findsNothing,
          reason: 'must never reach the real EMS home screen',
        );
        expect(find.text('Physician app'), findsOneWidget);
        expect(find.text('EMS app'), findsNothing);
        // Back to a clean, nobody-signed-in-yet email step — a plain local
        // UI reset (LoginScreen's own _useDifferentEmail), not a sign-out:
        // no real auth was ever attempted for this rejected account, so
        // there's no session to tear down and no reload risk here.
        await tapText($, 'Use a different email');
        await pumpUntil(
          $,
          () => find.text('Access denied').evaluate().isEmpty,
          maxIterations: 40,
        );
      }

      // ---- Sign in for real, as the one persistent EMS account, for all
      // phases below. ----
      //
      // signInWithTotp, not signIn+completeMfaEnrollment — this account
      // stays enrolled from run to run (see this file's own header
      // comment), so every sign-in hits the real second-factor *challenge*
      // an already-enrolled account gets, not the one-time setup screen.
      // Was Patrol's own $(TextField).at(0).enterText() — reliable all
      // session on Chrome, but this was the first time this exact line
      // ever ran for real on Android (Firebase Test Lab's Android e2e job
      // had been silently running zero tests until the native Patrol
      // setup was fixed — see android/app/src/androidTest/.../
      // MainActivityTest.java). First real run hit the identical hit-test
      // unreliability signIn's own enterTextAt call already covers, just
      // on a different platform/renderer than where it was originally
      // found.
      await signInWithTotp($, email, password, totpSecret);

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

      // patient_upload_screen.dart's own _onSubmit now shows this
      // confirmation dialog *before* it does any save work at all,
      // whenever a submit ends up on the stopTracking path — every submit
      // below does, either by explicitly toggling live tracking off or by
      // staying off from an earlier submit in this same flow. Tapping
      // Continue is what makes the save (and thus the stopTracking call,
      // and eventual home navigation) actually happen — this isn't just
      // dismissing a recap of something already done.
      Future<void> confirmTrackingOff() async {
        await pumpUntil(
          $,
          () => find
              .text(
                'You have location sharing turned off, if this was a mistake, click back, if was intentional, click continue',
              )
              .evaluate()
              .isNotEmpty,
          maxIterations: 40,
        );
        await tapText($, 'Continue');
      }

      // ---- Phase 1: add a patient, edit it, delete it. ----

      final patientName =
          'Patrol EMS Test Patient ${DateTime.now().millisecondsSinceEpoch}';

      // Fields, by index, on this form: 0=Name, 1=Age, 2=Healthcare
      // Number, 3=Heart Rate (Gender/Destination Hospital are dropdowns,
      // not TextFields, and aren't required to submit).
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
      await confirmTrackingOff();
      // Scoped to the home screen's own PatientSummaryCard, not a bare
      // find.text(patientName) — _onSubmit's success path (patient_upload_
      // screen.dart) navigates away via context.go('/') without first
      // clearing the Name field's controller, so for a moment both the
      // outgoing PatientUploadScreen's still-filled TextField (an
      // EditableText, which find.text() also matches) and the new card on
      // HomeScreen show the same text. Same class of bug, same fix, as
      // admin's user_flow_test.dart hospital-creation assertion — see that
      // file's own comment ("Confirmed via a real GHA failure ('Found 2
      // widgets')") for the precedent; hit for real here too, on Android
      // Test Lab specifically (2026-08-31 CI run).
      final patientCard = find.descendant(
        of: find.byType(PatientSummaryCard),
        matching: find.text(patientName),
      );
      await pumpUntil(
        $,
        () => patientCard.evaluate().isNotEmpty,
        maxIterations: 40,
      );
      expect(
        patientCard,
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
        // Retries the whole find-then-tap cycle, not just the initial
        // wait — confirmed via a real GHA failure on Firebase Test Lab's
        // ARM virtual device: pumpUntil found the button, but tapFinder's
        // own tap() threw "Found 0 widgets ... could not find any
        // matching widgets" on the very same finder moments later. The
        // home screen rebuilds on every Firestore snapshot from its own
        // live uploadedPatientsProvider watch (see cardButtonFor's own
        // comment above), and that gap between pumpUntil's check and
        // tap()'s own re-evaluation is apparently wide enough for one of
        // those rebuilds to land in between. Re-running the full
        // wait-then-tap cycle rides out a single bad rebuild.
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

      // Raw delete action, no assertions — reused below both for the
      // test's own real, asserted delete and as a best-effort cleanup
      // attempt if something else fails first (see the try/finally
      // around the rest of this phase).
      Future<void> deletePatient() async {
        await tapCardButton('Delete');
        await pumpUntil(
          $,
          () => find.text('Delete patient?').evaluate().isNotEmpty,
        );
        // The dialog's own confirm button is a FilledButton — distinct
        // from the card's OutlinedButton of the same label, so no extra
        // scoping needed to avoid hitting the card's button again by
        // mistake.
        await tapFinder($, find.widgetWithText(FilledButton, 'Delete'));
        await pumpUntil(
          $,
          () => find.text(patientName).evaluate().isEmpty,
          maxIterations: 40,
        );
      }

      // From here on, the patient definitely exists in Firestore — wrap
      // the rest of this phase (editing it, then deleting it for real) so
      // a failure partway through the edit still attempts to delete it,
      // instead of just leaving it orphaned for run-ems-patrol-test.mjs's
      // own createdBy-based sweep to eventually catch on some future run.
      // That sweep is still the real, guaranteed-to-work safety net for
      // whatever this can't manage (e.g. the app itself too broken to
      // find/tap Delete after some failures) — this just means the common
      // case doesn't have to wait for it.
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
        // Re-checked again immediately before the tap — see the Add
        // flow's identical call above for why (this is the exact spot a
        // real GHA failure confirmed it happening).
        await settleLocationPrompts($);
        await tapKey($, 'patient_upload_submit');
        // This patient's tracking was already off from phase 1's own
        // create step above, and this edit never touches the switch — so
        // it's still off, still routing through the same
        // confirmTrackingOff-needing path.
        await confirmTrackingOff();
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

      // ---- Phase 2: complete transport, export a FHIR record. ----
      //
      // Deliberately reuses the account phase 1 just signed in and
      // enrolled MFA with, rather than a fresh one — see this file's own
      // header comment for why that's not just an optimization here, it
      // removes a real cross-process MFA limitation the old two-file
      // version had to work around. No sign-in dance needed: still the
      // exact same continuous session as phase 1 above, never reloaded.

      final exportPatientName =
          'Patrol FHIR Export Test Patient ${DateTime.now().millisecondsSinceEpoch}';
      // The value the exported bundle's own heart-rate Observation should
      // echo back exactly (see the assertion below) — proving the round
      // trip (Firestore -> exportPatientFhirBundle's KMS decrypt + FHIR
      // mapping -> the real parsed response) actually carries the right
      // data, not just that some export "succeeded".
      const exportHeartRate = '88';

      // Captured as soon as the patient is uploaded (see below) and
      // deleted in `finally` regardless of how the rest of this phase
      // goes — this test owns cleaning up the exact data it creates,
      // rather than leaving it for some other process to eventually
      // sweep away.
      String? exportPatientId;
      try {
        // Fields, by index: 0=Name, 1=Age, 2=Healthcare Number, 3=Heart
        // Rate (Gender/Destination Hospital are dropdowns, not
        // TextFields, and aren't required to submit) — see phase 1 above.
        await tapText($, 'Add Patient');
        await pumpUntil(
          $,
          () => find.byType(PatientUploadScreen).evaluate().isNotEmpty,
        );
        await settleLocationPrompts($);
        await enterTextAt($, 0, exportPatientName);
        await enterTextAt($, 2, 'TEST-FHIR-12345');
        await enterTextAt($, 3, exportHeartRate);
        // Live tracking off — same reasoning as phase 1's identical step:
        // this CI environment has no real, granted browser geolocation.
        await tapFinder($, find.byType(SwitchListTile));
        await settleLocationPrompts($);
        await tapKey($, 'patient_upload_submit');
        await confirmTrackingOff();
        // Scoped to the home screen's own PatientSummaryCard, not a bare
        // find.text(exportPatientName) — same real race as phase 1's
        // identical fix above (_onSubmit's success path navigates away via
        // context.go('/') without first clearing the Name field's
        // controller, so for a moment both the outgoing screen's
        // still-filled TextField and the new card show the same text).
        // Phase 1 already had this fix; this occurrence didn't, and hit
        // the exact same "Found 2 widgets" failure for real on Android
        // Test Lab (2026-09-04 CI run) as a result.
        final exportPatientCard = find.descendant(
          of: find.byType(PatientSummaryCard),
          matching: find.text(exportPatientName),
        );
        await pumpUntil(
          $,
          () => exportPatientCard.evaluate().isNotEmpty,
          maxIterations: 40,
        );
        expect(
          exportPatientCard,
          findsOneWidget,
          reason: 'patient should appear on the home screen after upload',
        );
        exportPatientId = PatientUploadService.debugLastUploadedPatientId;
        expect(
          exportPatientId,
          isNotNull,
          reason: 'uploadPatient should have set debugLastUploadedPatientId',
        );

        // Scoped to this specific patient's own card — same reasoning as
        // phase 1's identical helpers (test-org can have other patients
        // whose cards render the exact same button text).
        Finder exportCardButtonFor(String buttonLabel) => find.descendant(
          of: find.ancestor(
            of: find.text(exportPatientName),
            matching: find.byType(Card),
          ),
          matching: find.widgetWithText(OutlinedButton, buttonLabel),
        );

        Future<void> tapExportCardButton(String buttonLabel) async {
          final finder = exportCardButtonFor(buttonLabel);
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

        // Complete transport — this chains directly into an automatic
        // FHIR export (see patient_summary_card.dart's _completeTransport
        // / _autoExportFhir for why there's no separate confirmation
        // dialog or button for the export itself): completing transport
        // removes this patient from this screen's own active-only list
        // immediately (patient_session_service.dart), and this card is
        // correctly *unmounted*, not reused, once it does (see
        // home_screen.dart's own comment on why each card is keyed by
        // patient id) — so there's no later moment a separately-
        // discoverable export button/dialog anchored to *this* card could
        // ever reliably work. run-ems-patrol-test.mjs seeds
        // fhirExportEnabled: true on test-org, so the export should fire
        // here automatically.
        debugLastExportResult = null;
        debugLastExportError = null;
        await tapExportCardButton('Complete Transport');
        await pumpUntil(
          $,
          () => find.text('Complete transport?').evaluate().isNotEmpty,
        );
        await tapFinder(
          $,
          find.widgetWithText(FilledButton, 'Complete Transport'),
        );

        // The real assertion: a genuine round trip through
        // exportPatientFhirBundle (functions/src/patients.ts) — org
        // lookup, status precondition, KMS decrypt path, FHIR resource
        // mapping, audit log — with the actual exported heart-rate
        // Observation's value read back out of the callable's real
        // response. Checked via amdash_core's debugLastExportResult/
        // debugLastExportError (an in-process capture — see its own doc
        // comment) rather than a widget in this card's own tree: this
        // card is expected to unmount shortly after completing transport,
        // well before the export (which runs against a widget-
        // independent ProviderContainer — see _autoExportFhir) actually
        // finishes, so there's no guaranteed-still-around success/error
        // Text to scan for instead.
        await pumpUntil(
          $,
          () => debugLastExportResult != null || debugLastExportError != null,
          maxIterations: 100,
        );
        // pumpUntil never throws on its own timeout — it just stops
        // polling and returns (confirmed by reading its source) — so
        // without this, a genuine timeout (neither value ever got set)
        // silently fell through to the null-check below instead of
        // reporting what actually happened. Hit for real in CI
        // (2026-09-05): the export call never resolved either way within
        // the wait budget, and this crashed with a confusing "Unexpected
        // null value" instead of a diagnosable timeout message.
        expect(
          debugLastExportResult != null || debugLastExportError != null,
          true,
          reason:
              'exportPatientFhirBundle should have resolved (success or error) within the wait budget, '
              'got neither — the export call itself may be slow/hung, not just this assertion',
        );
        if (debugLastExportError != null) {
          fail('Export failed: $debugLastExportError');
        }
        final bundle = debugLastExportResult!.bundle;
        final actualHeartRate = latestObservationValue(bundle, loincHeartRate);
        expect(
          actualHeartRate,
          int.parse(exportHeartRate),
          reason:
              "the exported FHIR bundle's heart rate observation should match what was actually entered for this "
              'patient (actual bundle heart-rate observation: $actualHeartRate)',
        );
      } finally {
        // Deletes this phase's own patient directly, rather than leaving
        // it for run-ems-patrol-test.mjs's own cleanup() sweep to
        // eventually notice and remove once this run's throwaway account
        // is deleted — that sweep is a real backstop for a genuinely
        // interrupted run (see its own comment), not something this test
        // should rely on for its *own* routine cleanup. Reuses the app's
        // own patientUploadServiceProvider (via the still-mounted
        // HomeScreen's own ProviderScope) rather than constructing a
        // fresh PatientUploadService by hand, so this goes through the
        // exact same deletePatientRecord callable the app's own Delete
        // button calls — no separate construction logic to keep in sync.
        // Runs regardless of whether this phase passed or failed, as long
        // as the patient was actually created (completing transport
        // doesn't remove the Firestore document itself, only this
        // screen's own active-only list membership — see
        // home_screen.dart — so this is still needed even after a
        // successful export).
        if (exportPatientId != null && find.byType(HomeScreen).evaluate().isNotEmpty) {
          try {
            final container = ProviderScope.containerOf(
              $.tester.element(find.byType(HomeScreen)),
              listen: false,
            );
            await container.read(patientUploadServiceProvider).deletePatient(exportPatientId);
          } catch (_) {
            // Best-effort — run-ems-patrol-test.mjs's own cleanup() sweep
            // is still a backstop if this somehow fails.
          }
        }
      }
    },
  );
}
