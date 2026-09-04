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
// Firebase Test Lab (see ci.yml's flutter-android-e2e-ems-onboarding job)
// — deliberately not Chrome, unlike the rest of this file's siblings,
// since EMS crews use the native app in the field, not the web build
// (which exists only for this repo's own Chrome e2e coverage — see
// ems_test.dart's header).
//
// tapText/enterTextAt/pumpUntil/completeMfaEnrollment come from
// amdash_patrol_helpers, shared across every app's patrol_test/ suite —
// see that package for the full rationale/history behind each one.
import 'package:amdash_patrol_helpers/amdash_patrol_helpers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ems/firebase_options.dart';
import 'package:ems/main.dart';
import 'package:ems/screens/home_screen.dart';
import 'package:ems/services/ems_alert_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
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

      // ---- Connectivity-alert push registration: verify a real FCM
      // token round trip. ----
      //
      // HomeScreen's own registerForConnectivityAlerts call (see
      // ems_alert_service.dart) fires once, unprompted, right on this
      // mount — fire-and-forget, so debugLastRegisterForConnectivityAlertsFinished
      // (a same-process, same-isolate debug flag — the same pattern
      // amdash_core's own debugLastExportResult/Error already uses, and
      // that ems_test.dart already reads directly) is what lets this wait
      // for the real requestPermission -> getToken -> Firestore-write
      // chain to actually finish, rather than racing it. This is the
      // whole point of retrofitting this phase onto Android specifically:
      // Test Lab's device runs genuine Google Play Services, so this can
      // complete for real here — unlike Patrol's Playwright-backed web
      // runner (see patient_flow_test.dart's identical rationale for its
      // own Enable-button phase).
      await pumpUntil(
        $,
        () => debugLastRegisterForConnectivityAlertsFinished,
        maxIterations: 60,
      );
      expect(
        debugLastRegisterForConnectivityAlertsError,
        isNull,
        reason:
            'registerForConnectivityAlerts should succeed for real on a Test Lab device — '
            'debugLastRegisterForConnectivityAlertsError: $debugLastRegisterForConnectivityAlertsError',
      );

      final uid = FirebaseAuth.instance.currentUser?.uid;
      expect(uid, isNotNull, reason: 'should be signed in by this point');
      // A signed-in user can read their own users/{uid} doc directly
      // (firestore.rules: `allow get: if ... request.auth.uid == userId`)
      // — no Admin SDK round trip needed to confirm this.
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final fcmTokens = userDoc.data()?['fcmTokens'];
      expect(
        fcmTokens is List && fcmTokens.isNotEmpty,
        true,
        reason: 'a real FCM token should have landed in users/$uid.fcmTokens, found: $fcmTokens',
      );
    },
  );
}
