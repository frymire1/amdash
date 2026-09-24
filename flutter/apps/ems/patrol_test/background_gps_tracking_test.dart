// Android only — real Test Lab device, run via Firebase Test Lab (see
// ci.yml's flutter-android-e2e job). Exists specifically to catch the bug
// this file was added for: on Android, EMS's live GPS tracking looked like
// it worked right up until the app was backgrounded, at which point the
// physician side eventually stopped seeing fresh fixes. Root cause and fix
// live in ems_tracking_service.dart (requestAndroidBackgroundUpgradeIfNeeded,
// debugLastFixAtMs) — this test proves the actual end-to-end promise: a fix
// still lands while the app is genuinely backgrounded, not just while it's
// in the foreground.
//
// Deliberately its own file/scenario, not folded into ems_test.dart's
// existing phases — this is the first scenario in this suite to grant real
// location permission (every other Android scenario denies it outright via
// Test Lab's own --grant-permissions=none, specifically to dodge the
// permission dependency rather than exercise it) and the first to use
// native app-backgrounding (`$.platform.mobile.pressHome`/`openApp`).
// Isolating it means a flake or failure here can't jeopardize the other,
// already-hardened scenarios, and vice versa. See ci.yml's own comment on
// this file's scenario for the accepted cost/flakiness tradeoff — this is
// a genuinely new kind of test for this suite (real OS permission dialogs,
// real backgrounding, a real race against Android's own foreground-service
// scheduling), not just another Flutter-level interaction, so treat a
// first-run failure as likely needing a hardening pass (retry loops,
// timing tweaks), the same way ems_test.dart's own history shows almost
// every one of its scenarios needed after their first real Test Lab run —
// not necessarily a sign the underlying fix is wrong.
//
// Reuses the SAME persistent EMS account ems_test.dart uses (see that
// file's own header comment on why sharing it is safe — no per-profile
// state this scenario could race against) — this step runs sequentially
// after run_ems in the same CI job, never concurrently with it.
//
// Test Lab's device runs Android 15 (API 35, see ci.yml's --device flag) —
// well into Android 11+ territory, where the OS never offers "Allow all
// the time" from an in-app dialog once foreground access is already
// granted (see requestAndroidBackgroundUpgradeIfNeeded's own doc comment).
// So this test only ever grants "While Using" — proving fixes still flow
// on exactly that grant level (via the foreground-service exemption) is
// the realistic, achievable claim here, not a second native dialog this
// specific device will never show regardless of app code.
import 'package:amdash_patrol_helpers/amdash_patrol_helpers.dart';
import 'package:ems/firebase_options.dart';
import 'package:ems/main.dart';
import 'package:ems/screens/home_screen.dart';
import 'package:ems/screens/patient_upload_screen.dart';
import 'package:ems/services/ems_tracking_service.dart';
import 'package:ems/widgets/patient_summary_card.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

// How long to stay backgrounded before checking for a fresh fix — enough
// margin over the foreground-service isolate's own 15s poll interval
// (ems_tracking_task_handler.dart) for at least two polls to plausibly
// land, even accounting for a loaded/slow CI device, without inflating
// this scenario's own Test Lab device-minutes further than needed to make
// the claim credible.
const _backgroundedWait = Duration(seconds: 40);

// Retries the whole find-then-tap cycle, not just the initial wait — same
// reasoning as ems_test.dart's own tapCardButton retry: a real GHA
// failure there found pumpUntil locating the target, then tapFinder's own
// tap() throwing "Found 0 widgets" moments later, since the screen
// rebuilds on every Firestore/Riverpod snapshot from a live watch. Hit
// for real here too, on the "Add Patient" tap specifically (2026-09-22 CI
// run, right after HomeScreen's own pumpUntil found it) — same root
// cause, same fix.
Future<void> _retryTap(PatrolIntegrationTester $, Finder finder) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    await pumpUntil($, () => finder.evaluate().isNotEmpty, maxIterations: 30);
    try {
      await tapFinder($, finder);
      return;
    } catch (_) {
      if (attempt == 2) rethrow;
      await $.pump(const Duration(milliseconds: 300));
    }
  }
}

void main() {
  patrolTest('a live-tracked patient keeps publishing GPS fixes while the app is backgrounded', (
    $,
  ) async {
    const email = String.fromEnvironment('SMOKE_EMAIL');
    const password = String.fromEnvironment('SMOKE_PASSWORD');
    const totpSecret = String.fromEnvironment('SMOKE_TOTP_SECRET');
    expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
    expect(password, isNotEmpty, reason: 'pass --dart-define=SMOKE_PASSWORD=...');
    expect(totpSecret, isNotEmpty, reason: 'pass --dart-define=SMOKE_TOTP_SECRET=...');

    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    await $.pumpWidgetAndSettle(const ProviderScope(child: EmsApp()));

    await signInWithTotp($, email, password, totpSecret);
    await pumpUntil($, () => find.byType(HomeScreen).evaluate().isNotEmpty, maxIterations: 50);

    // HomeScreen's own uploadedPatientsProvider watch keeps rebuilding the
    // screen for a while after this: first once the live Firestore
    // snapshot resolves (the CircularProgressIndicator below is that
    // signal), then AGAIN once withCachedDecryptedFields' own
    // decryptPatientFields Cloud Function round trip resolves for any of
    // this shared persistent account's existing patients — a real network
    // call with no visible loading indicator at all. Confirmed as the real
    // cause of this test's own recurring "Add Patient" tap flakiness
    // (2026-09-22/23 CI runs, both a "Found 0 widgets" and a "found the
    // widget but the tap didn't register" variant) via the Test Lab
    // logcat: repeated tap failures roughly 2s apart, matching two
    // separate rebuild waves rather than one. Two rounds of retrying the
    // tap itself (_retryTap below, and amdash_patrol_helpers' own
    // enterTextAt hardening) didn't fix it, since retrying doesn't help if
    // every retry still lands inside an active rebuild — waiting for the
    // known rebuild sources to actually finish first does. The spinner
    // wait covers the first rebuild; the fixed buffer covers the second,
    // unsignaled one (no widget-tree state to poll for it specifically).
    await pumpUntil($, () => find.byType(CircularProgressIndicator).evaluate().isEmpty, maxIterations: 30);
    await $.pump(const Duration(seconds: 3));

    final patientName = 'Patrol Background GPS Test Patient ${DateTime.now().millisecondsSinceEpoch}';

    await _retryTap($, find.text('Add Patient'));
    await pumpUntil($, () => find.byType(PatientUploadScreen).evaluate().isNotEmpty);

    // Grants "While Using" for real via Patrol's native permission API —
    // every other Android scenario in this suite denies here instead (see
    // this file's own header comment). Also clears the Play Services
    // "Location Accuracy" nudge and, if it somehow still appears despite
    // the grant, the in-app "Location permission is off" fallback — see
    // settleLocationPrompts' own doc comment for why every check still
    // runs regardless of grantLocation.
    await settleLocationPrompts($, grantLocation: true);

    // requestAndroidBackgroundUpgradeIfNeeded (ems_tracking_service.dart)
    // fires automatically right after the grant above resolves, as part of
    // the same _useCurrentLocation() call — including
    // FlutterForegroundTask.requestIgnoreBatteryOptimization(), a
    // *different* system dialog type isPermissionDialogVisible/
    // settleLocationPrompts above don't cover (that one only watches the
    // standard runtime-permission dialog). Best-effort dismiss: not
    // required for tracking to work either way (see that method's own doc
    // comment on why it's wrapped in try/catch there too), and whether
    // this dialog appears at all is OEM/OS-specific.
    try {
      await $.platform.tap(Selector(text: 'Allow'), timeout: const Duration(seconds: 3));
      await $.pump(const Duration(milliseconds: 300));
    } catch (_) {
      // Not present, or didn't match this device's exact wording — fine
      // either way, see this block's own comment above.
    }

    // Fields, by index: 0=Name, 2=Healthcare Number, 3=Heart Rate — same
    // shape as ems_test.dart's own Add Patient flow (1=Age and the two
    // dropdowns aren't required to submit).
    await enterTextAt($, 0, patientName);
    await enterTextAt($, 2, 'TEST-BG-GPS-12345');
    await enterTextAt($, 3, '80');
    // Live tracking stays ON here (the form's own default) — the entire
    // point of this scenario, unlike every other Android scenario in this
    // suite, which explicitly turns it off to dodge the permission
    // dependency this test exists to exercise.
    await settleLocationPrompts($, grantLocation: true);
    await _retryTap($, find.byKey(const Key('patient_upload_submit')));

    final patientCard = find.descendant(of: find.byType(PatientSummaryCard), matching: find.text(patientName));
    await pumpUntil($, () => patientCard.evaluate().isNotEmpty, maxIterations: 40);
    expect(patientCard, findsOneWidget, reason: 'patient should appear on the home screen after upload');

    // Baseline: the confirming publish startTracking() already made as
    // part of the submit above. Wrapped in a try/finally from here so a
    // failed assertion below still attempts real cleanup (stop tracking,
    // delete the patient) rather than leaving the account with an
    // orphaned actively-tracked patient — run-ems-patrol-test.mjs's own
    // createdBy-based sweep is a backstop for a genuinely interrupted run,
    // not something this test's own routine path should rely on.
    final baselineFixAtMs = EmsTrackingController.debugLastFixAtMs;
    expect(baselineFixAtMs, isNotNull, reason: 'the confirming publish at submit time should have recorded a fix');
    // Diagnostic only (not an assertion) — narrows down *where* a failure
    // below actually lives if one happens: isRunningService false means
    // the foreground service itself never started/already died; true
    // means it's alive and the gap is somewhere inside its own recurring
    // publish logic instead (see ems_tracking_task_handler.dart's own new
    // onRepeatEvent/_publishAllTracked debugPrint calls for the next
    // layer down).
    debugPrint('DIAG: isRunningService before backgrounding = ${await FlutterForegroundTask.isRunningService}');

    try {
      await $.platform.mobile.pressHome();
      await Future<void>.delayed(_backgroundedWait);
      await $.platform.mobile.openApp();
      // Lets any pending rebuilds from resuming settle before reading
      // state or interacting further — not waiting on anything specific,
      // since the widget tree survives backgrounding (this only pressed
      // Home, never navigated away or killed the process).
      await $.pump(const Duration(seconds: 1));

      debugPrint('DIAG: isRunningService after resuming = ${await FlutterForegroundTask.isRunningService}');
      final resumedFixAtMs = EmsTrackingController.debugLastFixAtMs;
      expect(
        resumedFixAtMs,
        isNotNull,
        reason: 'should still have a recorded fix after resuming from background',
      );
      expect(
        resumedFixAtMs! > baselineFixAtMs!,
        true,
        reason:
            'a fresh fix should have been recorded while the app was backgrounded '
            '(baseline: $baselineFixAtMs, after resuming: $resumedFixAtMs) — if this is '
            'equal, the foreground service likely stopped publishing while backgrounded',
      );

      // Confirms the app is actually back in a normal, interactable state
      // post-resume too, not just that the debug counter moved — the
      // cleanup below depends on this screen still being real and
      // responsive.
      await pumpUntil($, () => find.byType(HomeScreen).evaluate().isNotEmpty, maxIterations: 40);
      expect(patientCard, findsOneWidget, reason: 'patient card should still be there after resuming');
    } finally {
      // _deletePatient (patient_summary_card.dart) calls stopTracking
      // itself before deleting — no separate stop-tracking step needed
      // here. Scoped to this specific patient's own card, same reasoning
      // as ems_test.dart's identical helpers (test-org can have other
      // patients whose cards render the same button text).
      if (find.text(patientName).evaluate().isNotEmpty) {
        try {
          final cardButton = find.descendant(
            of: find.ancestor(of: find.text(patientName), matching: find.byType(Card)),
            matching: find.widgetWithText(OutlinedButton, 'Delete'),
          );
          for (var attempt = 0; attempt < 3; attempt++) {
            await pumpUntil($, () => cardButton.evaluate().isNotEmpty, maxIterations: 30);
            try {
              await tapFinder($, cardButton);
              break;
            } catch (_) {
              if (attempt == 2) rethrow;
              await $.pump(const Duration(milliseconds: 300));
            }
          }
          await pumpUntil($, () => find.text('Delete patient?').evaluate().isNotEmpty, maxIterations: 30);
          await tapFinder($, find.widgetWithText(FilledButton, 'Delete'));
          await pumpUntil($, () => find.text(patientName).evaluate().isEmpty, maxIterations: 40);
        } catch (_) {
          // Best-effort — see this block's own comment above.
        }
      }
    }
  });
}
