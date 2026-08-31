// Failure-state sibling of first_login_test.dart (see
// run-physician-onboarding-e2e.mjs, which orchestrates both): an
// admin-created account with the *ems* role — not physician — attempting
// its first-ever sign-in through the physician app. checkAccountStatus/
// setInitialPassword/MFA enrollment don't check role at all (see
// functions/src/auth.ts and mfa_service.dart), so this account can
// genuinely set a password and enroll MFA here exactly like a real
// physician account would — the actual authorization boundary is
// AppRouteGuard's role tier (amdash_core/lib/src/guards/app_guards.dart),
// which only runs *after* auth+MFA both succeed (and, notably, *before*
// physician's own work-location tier — an ems-role account never reaches
// /work-location at all). This test exists to prove that boundary
// actually holds for a real account doing a real first sign-in, not just
// that the guard function returns the right string in a unit test.
//
// tapText/enterTextAt/pumpUntil/completeMfaEnrollment come from
// amdash_patrol_helpers, shared across every app's patrol_test/ suite —
// see that package for the full rationale/history behind each one.
import 'package:amdash_core/amdash_core.dart';
import 'package:amdash_patrol_helpers/amdash_patrol_helpers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:physician/firebase_options.dart';
import 'package:physician/main.dart';
import 'package:physician/screens/main_view_screen.dart';

void main() {
  patrolTest(
    'an ems-only account signing in for the first time through the physician app is denied access',
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
      await $.pumpWidgetAndSettle(const ProviderScope(child: PhysicianApp()));

      await enterTextAt($, 0, email);
      await tapText($, 'Continue');

      // Same as a real physician account's first sign-in — role isn't
      // checked yet at this point, only that the account exists and has
      // no password.
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
      // MainViewScreen or /work-location — AppRouteGuard's role tier runs
      // before its work-location tier, so an ems-only account never even
      // reaches the hospital-picker step.
      await pumpUntil(
        $,
        () => find.byType(AccessDeniedScreen).evaluate().isNotEmpty,
        maxIterations: 50,
      );
      expect(
        find.byType(AccessDeniedScreen),
        findsOneWidget,
        reason: 'an ems-only account should be denied access to the physician app',
      );
      expect(
        find.byType(MainViewScreen),
        findsNothing,
        reason: 'must never reach the real physician main view',
      );
      expect(find.text('Select Your Hospital'), findsNothing, reason: 'must never reach work-location setup either');
      expect(find.textContaining("doesn't have access to the"), findsOneWidget);
      // AccessDeniedScreen's "try one of your other apps" list is derived
      // from the account's real roles — this account is ems-only, so
      // exactly the EMS app link should be offered, not Physician or
      // Admin.
      expect(find.text('EMS app'), findsOneWidget);
      expect(find.text('Physician app'), findsNothing);
      expect(find.text('Admin app'), findsNothing);
    },
  );
}
