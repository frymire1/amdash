// Cross-app onboarding verification (see scripts/run-physician-onboarding-
// e2e.mjs, which orchestrates this after admin/patrol_test/
// create_user_test.dart creates the account this test signs into): the
// real first-ever sign-in experience for an admin-created account — no
// password yet, so checkAccountStatus reports hasPassword: false and the
// login screen lands on "set your password" instead of the normal
// sign-in step every other test's account skips straight past (those are
// all seeded directly via the Admin SDK with a password already set —
// see run-physician-patrol-test.mjs). Runs via `patrol test --device
// chrome` against real Chrome, real Firebase Auth/Firestore/Cloud
// Functions on amdash-dev.
//
// tapText/enterTextAt/pumpUntil/completeMfaEnrollment come from
// amdash_patrol_helpers, shared across every app's patrol_test/ suite —
// see that package for the full rationale/history behind each one.
import 'package:amdash_patrol_helpers/amdash_patrol_helpers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:physician/firebase_options.dart';
import 'package:physician/main.dart';
import 'package:physician/screens/main_view_screen.dart';

void main() {
  patrolTest(
    'a newly admin-created physician account completes its first-ever sign-in',
    ($) async {
      const email = String.fromEnvironment('SMOKE_EMAIL');
      const newPassword = String.fromEnvironment('SMOKE_NEW_PASSWORD');
      const hospitalName = String.fromEnvironment('SMOKE_HOSPITAL');
      expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
      expect(
        newPassword,
        isNotEmpty,
        reason: 'pass --dart-define=SMOKE_NEW_PASSWORD=...',
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

      await enterTextAt($, 0, email);
      await tapText($, 'Continue');

      // This is the whole point of this test: a brand-new, admin-created
      // account with no password yet lands here, not on the normal
      // sign-in step.
      await pumpUntil(
        $,
        () => find
            .text("Your admin team has set up your account, now just create a password.")
            .evaluate()
            .isNotEmpty,
        maxIterations: 40,
      );

      await enterTextAt($, 0, newPassword);
      await enterTextAt($, 1, newPassword);
      await tapText($, 'Set Password');

      await completeMfaEnrollment($);

      // Work location — first-time setup, same flow patient_flow_test.dart
      // drives for its own (Admin-SDK-seeded, but equally workLocation-less)
      // account; see that file's own comment for why this is tapped
      // directly rather than via tapFinder.
      await $.pump(const Duration(seconds: 2));
      if ($('Select Your Hospital').exists) {
        await enterTextAt($, 0, hospitalName);
        await pumpUntil($, () => find.text(hospitalName).evaluate().isNotEmpty);
        final hospitalMatches = find.text(hospitalName);
        await $.tester.tap(
          hospitalMatches.at(hospitalMatches.evaluate().length - 1),
        );
        await $.pump(const Duration(milliseconds: 400));
        FocusManager.instance.primaryFocus?.unfocus();
        await $.pump(const Duration(milliseconds: 300));
        await tapText($, 'Continue');
      }

      await pumpUntil(
        $,
        () => find.byType(MainViewScreen).evaluate().isNotEmpty,
        maxIterations: 100,
      );
      expect(
        find.byType(MainViewScreen),
        findsOneWidget,
        reason: 'should land on the main view after first sign-in',
      );
    },
  );
}
