// Failure-state sibling of first_login_test.dart (see
// run-ems-onboarding-e2e.mjs, which orchestrates both): an admin-created
// account with the *physician* role — not ems — attempting its first-ever
// sign-in through the EMS app. checkAccountStatus/setInitialPassword/MFA
// enrollment don't check role at all (see functions/src/auth.ts and
// mfa_service.dart), so this account can genuinely set a password and
// enroll MFA here exactly like a real ems account would — the actual
// authorization boundary is AppRouteGuard's role tier
// (amdash_core/lib/src/guards/app_guards.dart), which only runs *after*
// auth+MFA both succeed. This test exists to prove that boundary actually
// holds for a real account doing a real first sign-in, not just that the
// guard function returns the right string in a unit test.
//
// tapText/enterTextAt/pumpUntil/completeMfaEnrollment come from
// amdash_patrol_helpers, shared across every app's patrol_test/ suite —
// see that package for the full rationale/history behind each one.
import 'package:amdash_core/amdash_core.dart';
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
    'a physician-only account signing in for the first time through the EMS app is denied access',
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

      // Same as a real ems account's first sign-in — role isn't checked
      // yet at this point, only that the account exists and has no
      // password.
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

      // The actual boundary: AccessDeniedScreen (amdash_core), not
      // HomeScreen — AppRouteGuard's role tier only runs after auth+MFA
      // both succeed, so this is the first point in the whole flow where
      // "wrong app for this account" can actually be caught.
      await pumpUntil(
        $,
        () => find.byType(AccessDeniedScreen).evaluate().isNotEmpty,
        maxIterations: 50,
      );
      expect(
        find.byType(AccessDeniedScreen),
        findsOneWidget,
        reason: 'a physician-only account should be denied access to the EMS app',
      );
      expect(
        find.byType(HomeScreen),
        findsNothing,
        reason: 'must never reach the real EMS home screen',
      );
      expect(find.textContaining("doesn't have access to the"), findsOneWidget);
      // AccessDeniedScreen's "try one of your other apps" list is derived
      // from the account's real roles — this account is physician-only,
      // so exactly the Physician app link should be offered, not EMS or
      // Admin.
      expect(find.text('Physician app'), findsOneWidget);
      expect(find.text('EMS app'), findsNothing);
      expect(find.text('Admin app'), findsNothing);
    },
  );
}
