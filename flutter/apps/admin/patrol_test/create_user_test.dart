// Shared by both cross-app onboarding e2e flows (see run-ems-onboarding-
// e2e.mjs / run-physician-onboarding-e2e.mjs): the admin half of "admin
// creates a user, then that user's own first-ever sign-in completes it."
// Deliberately narrower than user_flow_test.dart's own user-creation
// step — this test's only job is creating the account and confirming it
// shows up, not exercising role edit/hospital/retention too. Runs via
// `patrol test --device chrome` against real Chrome, real Firebase Auth/
// Firestore/Cloud Functions on amdash-dev, same as every other patrol_test
// suite in this repo.
//
// The account this creates deliberately gets NO password — that's the
// whole point: it's created purely through the real createUser Cloud
// Function (via the app's own UI, not seeded by Admin SDK), so the
// ems/physician onboarding test that signs into it next genuinely hits
// checkAccountStatus's hasPassword: false branch and the real "set your
// password" flow, not a shortcut.
//
// tapKey/tapText/pumpUntil/completeMfaEnrollment come from
// amdash_patrol_helpers, shared across every app's patrol_test/ suite —
// see that package for the full rationale/history behind each one.
import 'package:admin/firebase_options.dart';
import 'package:admin/main.dart';
import 'package:admin/screens/user_management_screen.dart';
import 'package:amdash_patrol_helpers/amdash_patrol_helpers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

void main() {
  patrolTest(
    'admin creates a new passwordless user, for a later first-login test',
    ($) async {
      const email = String.fromEnvironment('SMOKE_EMAIL');
      const password = String.fromEnvironment('SMOKE_PASSWORD');
      const newUserEmail = String.fromEnvironment('SMOKE_NEW_USER_EMAIL');
      // 'ems' or 'physician' — matches UserRole.wireValue exactly, since
      // it's used directly as the add_user_role_option_$newUserRole key
      // below (see user_management_screen.dart).
      const newUserRole = String.fromEnvironment('SMOKE_NEW_USER_ROLE');
      expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
      expect(
        password,
        isNotEmpty,
        reason: 'pass --dart-define=SMOKE_PASSWORD=...',
      );
      expect(
        newUserEmail,
        isNotEmpty,
        reason: 'pass --dart-define=SMOKE_NEW_USER_EMAIL=...',
      );
      expect(
        newUserRole,
        isNotEmpty,
        reason: 'pass --dart-define=SMOKE_NEW_USER_ROLE=... (ems or physician)',
      );

      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      await $.pumpWidgetAndSettle(const ProviderScope(child: AdminApp()));

      // Sign in as the (already-onboarded) admin account.
      await $(TextField).at(0).enterText(email);
      await tapText($, 'Continue');
      await pumpUntil($, () => find.text('Sign In').evaluate().isNotEmpty);
      await $(TextField).at(0).enterText(password);
      await tapText($, 'Sign In');
      await completeMfaEnrollment($);

      await pumpUntil(
        $,
        () => find.byType(UserManagementScreen).evaluate().isNotEmpty,
        maxIterations: 50,
      );

      // Create the new user — dropdown options are targeted by key, not
      // text, same reasoning as user_flow_test.dart's identical step: a
      // bare find.text(newUserRole) also matches any pre-existing user's
      // role chip elsewhere on the page.
      await $(TextField).at(0).enterText(newUserEmail);
      await $(TextField).at(1).enterText('Patrol');
      await $(TextField).at(2).enterText('Onboarding');
      await tapKey($, 'add_user_role_dropdown');
      await tapKey($, 'add_user_role_option_$newUserRole');
      await tapKey($, 'add_user_submit');
      await pumpUntil(
        $,
        () => find.text(newUserEmail).evaluate().isNotEmpty,
        maxIterations: 40,
      );
      expect(
        find.text(newUserEmail),
        findsOneWidget,
        reason: 'user should have been created within the wait budget',
      );
    },
  );
}
