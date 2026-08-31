// Cross-app onboarding verification (see scripts/run-ems-onboarding-
// e2e.mjs, which orchestrates this after admin/patrol_test/
// create_user_test.dart creates the account this test signs into — driven
// via Chrome, since admin has no native Android/iOS build at all): the
// real first-ever sign-in experience for an admin-created account — no
// password yet, so checkAccountStatus reports hasPassword: false and the
// login screen lands on "set your password" instead of the normal
// sign-in step every other EMS test's account skips straight past (those
// are all seeded directly via the Admin SDK with a password already set
// — see run-ems-patrol-test.mjs). Runs on a real Android device via
// Firebase Test Lab (see ci.yml's flutter-android-e2e job) — deliberately
// not Chrome, unlike the rest of this file's siblings, since EMS crews
// use the native app in the field, not the web build (which exists only
// for this repo's own Chrome e2e coverage — see ems_test.dart's header).
//
// tapText/enterTextAt/pumpUntil/completeMfaEnrollment come from
// amdash_patrol_helpers, shared across every app's patrol_test/ suite —
// see that package for the full rationale/history behind each one.
import 'package:amdash_patrol_helpers/amdash_patrol_helpers.dart';
import 'package:ems/firebase_options.dart';
import 'package:ems/main.dart';
import 'package:ems/screens/home_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

void main() {
  patrolTest(
    'a newly admin-created ems account completes its first-ever sign-in',
    ($) async {
      const email = String.fromEnvironment('SMOKE_EMAIL');
      const newPassword = String.fromEnvironment('SMOKE_NEW_PASSWORD');
      expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
      expect(
        newPassword,
        isNotEmpty,
        reason: 'pass --dart-define=SMOKE_NEW_PASSWORD=...',
      );

      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      await $.pumpWidgetAndSettle(const ProviderScope(child: EmsApp()));

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

      await pumpUntil(
        $,
        () => find.byType(HomeScreen).evaluate().isNotEmpty,
        maxIterations: 50,
      );
      expect(
        find.byType(HomeScreen),
        findsOneWidget,
        reason: 'should land on the home screen after first sign-in',
      );
    },
  );
}
