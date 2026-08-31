// Failure-state sibling of first_login_test.dart (see
// run-ems-onboarding-e2e.mjs, which orchestrates both): an admin-created
// account with the *physician* role — not ems — attempting to sign in
// through the EMS app. checkAccountStatus now checks role server-side
// right after the caller identifies themselves by email (see
// functions/src/auth.ts's accountRoleInfo and LoginScreen's own
// allowedRoles), so this account is rejected immediately — it never
// reaches set-password or MFA enrollment at all, unlike before this
// existed (see git history for the version of this test that had to walk
// through both to prove the same boundary).
//
// The "try one of your other apps" link's own real navigation is verified
// at the widget-test level instead of here (login_screen_test.dart's
// "wrong-app step" group, mirroring access_denied_screen_test.dart's own
// mocked-UrlLauncherPlatform pattern) — that's the established, reliable
// way this codebase confirms a launchUrl call actually targets the right
// URL; a real e2e run has no reliable way to observe whether an OS-level
// browser tab actually opened. This test confirms the right link is
// *offered* on a real device, which a widget test can't — the rest is a
// widget-test concern.
//
// tapText/enterTextAt/pumpUntil come from amdash_patrol_helpers, shared
// across every app's patrol_test/ suite — see that package for the full
// rationale/history behind each one.
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
    'a physician-only account is denied access to the EMS app immediately after entering their email',
    ($) async {
      const email = String.fromEnvironment('SMOKE_EMAIL');
      expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');

      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      await $.pumpWidgetAndSettle(const ProviderScope(child: EmsApp()));

      await enterTextAt($, 0, email);
      await tapText($, 'Continue');

      // The actual boundary, now reached right after email — no password,
      // no MFA. checkAccountStatus's own roleAllowed field is what makes
      // this immediate, not AppRouteGuard's post-auth role tier (which
      // still exists as the real enforcement backstop, just isn't what a
      // legitimate account ever has to walk through to be told this).
      await pumpUntil(
        $,
        () => find.text('Access denied').evaluate().isNotEmpty,
        maxIterations: 40,
      );
      expect(find.text('Access denied'), findsOneWidget);
      expect(find.textContaining("doesn't have access to the AmDash — EMS app"), findsOneWidget);
      expect(
        find.text("Your admin team has set up your account, now just create a password."),
        findsNothing,
        reason: 'must never reach the set-password step',
      );
      expect(find.byType(HomeScreen), findsNothing, reason: 'must never reach the real EMS home screen');

      // This account is physician-only, so exactly the Physician app link
      // should be offered — not EMS or Admin.
      expect(find.text('Physician app'), findsOneWidget);
      expect(find.text('EMS app'), findsNothing);
      expect(find.text('Admin app'), findsNothing);
    },
  );
}
