// Phase 3 verification: runs via `patrol test --device chrome` against
// real Chrome, real Firebase Auth/Firestore/Cloud Functions on
// amdash-dev. The throwaway admin account this signs in with is created
// directly via the Firebase Admin SDK, not by this test — pass its
// email/password via --dart-define, same convention as the EMS/physician
// apps' own tests.
import 'package:admin/main.dart';
import 'package:admin/screens/organization_settings_screen.dart';
import 'package:admin/screens/user_management_screen.dart';
import 'package:admin/widgets/edit_user_dialog.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otp/otp.dart';
import 'package:patrol/patrol.dart';

import 'package:admin/firebase_options.dart';

// Patrol's own `.tap()`/`.waitUntilVisible()` require a widget to pass
// its hit-testable check, which — verified manually against a real
// browser, where every one of these interactions works fine — proved
// intermittently unreliable against this app's Material overlays
// (dropdown menus) and, at least once, an entirely ordinary always-visible
// button. Tapping through the raw WidgetTester instead (only requires the
// widget to exist, then simulates the tap at its center directly) has
// been reliable throughout, so every interaction in this test uses it
// consistently rather than mixing the two.
Future<void> tapFinder(PatrolIntegrationTester $, Finder finder) async {
  // AdminPage wraps every screen's content in a SingleChildScrollView, and
  // this test's own actions (creating a user, etc.) grow the page tall
  // enough that later controls — e.g. the "Add Hospital" button — end up
  // below the fold of the fixed test viewport. $.tester.tap() only checks
  // that the widget exists and computes its center, it doesn't scroll it
  // into view first, so a real click dispatched by Playwright at that
  // (off-screen) coordinate hits nothing. ensureVisible scrolls the
  // nearest Scrollable ancestor first, same as a real user would.
  await $.tester.ensureVisible(finder);
  await $.pump(const Duration(milliseconds: 200));
  await $.tester.tap(finder);
  await $.pump(const Duration(milliseconds: 400));
}

Future<void> tapKey(PatrolIntegrationTester $, String key) =>
    tapFinder($, find.byKey(Key(key)));

Future<void> tapText(PatrolIntegrationTester $, String text) =>
    tapFinder($, find.text(text));

Future<void> tapIcon(PatrolIntegrationTester $, IconData icon) =>
    tapFinder($, find.byIcon(icon).first);

/// Patrol's own `$(...).enterText()` has the same missing-scroll gap as its
/// `.tap()` (see tapFinder's comment above) — fine for fields already near
/// the top of a page (sign-in, add-user), but the Settings page stacks
/// several cards above HospitalManagementSection, putting its Name/Address
/// fields below the fold on the fixed test viewport. ensureVisible first,
/// same fix as every button interaction in this file already gets.
Future<void> enterTextAt(
  PatrolIntegrationTester $,
  int index,
  String text,
) async {
  final finder = find.byType(TextField).at(index);
  await $.tester.ensureVisible(finder);
  await $.pump(const Duration(milliseconds: 200));
  await $.tester.enterText(finder, text);
  await $.pump(const Duration(milliseconds: 200));
}

/// Polls with fixed pumps rather than a one-shot wait — network round
/// trips (Cloud Function calls + Firestore listener updates) don't always
/// land inside a short fixed pump.
Future<void> pumpUntil(
  PatrolIntegrationTester $,
  bool Function() condition, {
  int maxIterations = 50,
}) async {
  for (var i = 0; i < maxIterations; i++) {
    if (condition()) return;
    await $.pump(const Duration(milliseconds: 400));
  }
}

/// Every account requires TOTP MFA (`AppRouteGuard`'s `requireMfa` tier,
/// checked right after auth and before anything else) — a freshly created
/// throwaway account has never enrolled, so sign-in always lands on
/// /mfa-setup first. There's no server-side shortcut: the Admin SDK can
/// only pre-enroll *phone* factors, not TOTP, so this drives the real
/// enrollment UI instead of bypassing it — reads the on-screen secret and
/// computes an actual valid code, exactly like a real authenticator app
/// would. The account is created with emailVerified: true already (see
/// run-admin-patrol-test.mjs), so /mfa-setup goes straight to the TOTP
/// step without an email-verification detour.
Future<void> completeMfaEnrollment(PatrolIntegrationTester $) async {
  await pumpUntil(
    $,
    () => find.byKey(const Key('mfa_secret_key')).evaluate().isNotEmpty,
    maxIterations: 40,
  );
  final secret = $.tester
      .widget<SelectableText>(find.byKey(const Key('mfa_secret_key')))
      .data!;
  // SHA1/6 digits/30s is the universal TOTP convention every authenticator
  // app assumes and the one Firebase's TOTP implementation actually uses
  // (TotpSecret exposes these as fields, but the enrollment UI doesn't
  // surface them — there's no Firebase-side way to configure anything
  // else, so hard-coding the standard is safe, not an assumption).
  final code = OTP.generateTOTPCodeString(
    secret,
    DateTime.now().millisecondsSinceEpoch,
    algorithm: Algorithm.SHA1,
    isGoogle: true,
  );
  await $(TextField).enterText(code);
  await tapText($, 'Confirm');
  await pumpUntil(
    $,
    () => find.byKey(const Key('mfa_secret_key')).evaluate().isEmpty,
    maxIterations: 30,
  );
}

void main() {
  patrolTest(
    'admin creates a user, assigns/removes a role, manages a hospital, and toggles retention',
    ($) async {
      const email = String.fromEnvironment('SMOKE_EMAIL');
      const password = String.fromEnvironment('SMOKE_PASSWORD');
      expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
      expect(
        password,
        isNotEmpty,
        reason: 'pass --dart-define=SMOKE_PASSWORD=...',
      );

      final newUserEmail =
          'patrol-created-${DateTime.now().millisecondsSinceEpoch}@amdash-e2e.test';
      final hospitalName =
          'Patrol Test Hospital ${DateTime.now().millisecondsSinceEpoch}';

      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      await $.pumpWidgetAndSettle(const ProviderScope(child: AdminApp()));

      // Sign in.
      await $(TextField).at(0).enterText(email);
      await tapText($, 'Continue');
      await pumpUntil($, () => find.text('Sign In').evaluate().isNotEmpty);

      await $(TextField).at(0).enterText(password);
      await tapText($, 'Sign In');

      await completeMfaEnrollment($);

      // Landing redirect sends an admin to /users.
      await pumpUntil(
        $,
        () => find.byType(UserManagementScreen).evaluate().isNotEmpty,
        maxIterations: 50,
      );
      expect(
        find.byType(UserManagementScreen),
        findsOneWidget,
        reason: 'should have reached the main view',
      );

      // Create a user (ems role). Dropdown options are targeted by key,
      // not text — a bare find.text('ems') also matches any pre-existing
      // user's role chip elsewhere on the page.
      await $(TextField).at(0).enterText(newUserEmail);
      await $(TextField).at(1).enterText('Patrol');
      await $(TextField).at(2).enterText('Created');
      await tapKey($, 'add_user_role_dropdown');
      await tapKey($, 'add_user_role_option_ems');
      await tapKey($, 'add_user_submit');
      await pumpUntil($, () => find.text(newUserEmail).evaluate().isNotEmpty);
      expect(
        find.text(newUserEmail),
        findsOneWidget,
        reason: 'user should have been created within the wait budget',
      );

      // Open the Edit User dialog for the user just created — keyed by
      // email so this targets exactly that row, not "first in the table"
      // (test-org accumulates other real/leftover users across runs).
      await pumpUntil(
        $,
        () => find.byKey(Key('edit_user_$newUserEmail')).evaluate().isNotEmpty,
        maxIterations: 20,
      );
      await tapKey($, 'edit_user_$newUserEmail');
      await $.pump(const Duration(milliseconds: 300));

      // Assign a second role (physician) from inside the dialog. Keyed the
      // same way the old top-level Assign a Role form was — key-based taps
      // have been 100% reliable throughout this test, plain find.text taps
      // on Material dropdown/button widgets have not.
      await tapKey($, 'edit_role_dropdown');
      await tapKey($, 'edit_role_option_physician');
      await tapKey($, 'edit_role_add_button');
      // Scoped to the dialog itself, not a bare find.text('physician') — the
      // dialog is a modal overlay, not a replacement route, so the user
      // table underneath stays mounted, and test-org's accumulated
      // leftover users (from other runs, or earlier runs that failed
      // mid-test before their own cleanup ran) can easily have their own
      // "physician" role chips elsewhere on that table.
      final physicianChipInDialog = find.descendant(
        of: find.byType(EditUserDialog),
        matching: find.text('physician'),
      );
      await pumpUntil(
        $,
        () => physicianChipInDialog.evaluate().isNotEmpty,
        maxIterations: 60,
      );
      expect(
        physicianChipInDialog,
        findsOneWidget,
        reason: 'role assignment should have succeeded within the wait budget',
      );

      // Remove a role via its chip's close button — scoped to this user
      // already, since only their dialog is open (unlike the old table,
      // whose remove buttons weren't independently scoped per row).
      await pumpUntil(
        $,
        () => find.byIcon(Icons.close).evaluate().isNotEmpty,
        maxIterations: 40,
      );
      await tapIcon($, Icons.close);
      await $.pump(const Duration(seconds: 2));

      await tapKey($, 'edit_user_dialog_close');
      await $.pump(const Duration(milliseconds: 300));

      // Navigate to Settings via the hamburger menu — hospital management
      // now lives here instead of its own tab.
      await tapIcon($, Icons.menu);
      await tapText($, 'Settings');
      await pumpUntil(
        $,
        () => find.byType(OrganizationSettingsScreen).evaluate().isNotEmpty,
      );

      // Create a hospital. createHospital calls out to Google's
      // Geocoding API server-side (plus a possible Cloud Function cold
      // start), so this gets a longer budget than the Firestore-only
      // writes above.
      await enterTextAt($, 0, hospitalName);
      await enterTextAt($, 1, '123 Main St, Toronto, ON');
      await tapKey($, 'add_hospital_submit');
      await pumpUntil(
        $,
        () => find.text(hospitalName).evaluate().isNotEmpty,
        maxIterations: 60,
      );
      expect(
        find.text(hospitalName),
        findsOneWidget,
        reason: 'hospital should have been created within the wait budget',
      );

      // Delete it again — scoped to this specific hospital's own delete
      // button by key, not Icons.delete_outline.first, since test-org
      // accumulates other real/leftover hospitals from other test runs
      // and "first" isn't reliably this one. hospitalsProvider is a live
      // Firestore stream, so the row carrying the hospital's name can
      // render a beat before the same row's delete IconButton settles —
      // wait for the key itself, not just the name text.
      await pumpUntil(
        $,
        () => find
            .byKey(Key('delete_hospital_$hospitalName'))
            .evaluate()
            .isNotEmpty,
        maxIterations: 20,
      );
      await tapKey($, 'delete_hospital_$hospitalName');
      await pumpUntil(
        $,
        () => find.text(hospitalName).evaluate().isEmpty,
        maxIterations: 50,
      );
      expect(find.text(hospitalName), findsNothing);

      // Still on Settings — toggle retention.

      // The Switch's value reflects a live Firestore listener, not local
      // optimistic state (see the screen's own doc comment), so it only
      // flips once the Cloud Function write round trips back through the
      // listener — a flat pump isn't a reliable wait for that, poll for it.
      final initialValue = $.tester.widget<Switch>(find.byType(Switch)).value;
      await tapFinder($, find.byType(Switch));
      await pumpUntil(
        $,
        () =>
            $.tester.widget<Switch>(find.byType(Switch)).value != initialValue,
        maxIterations: 40,
      );
      expect($.tester.widget<Switch>(find.byType(Switch)).value, !initialValue);

      // Toggle it back so the org's setting isn't left changed.
      await tapFinder($, find.byType(Switch));
      await pumpUntil(
        $,
        () =>
            $.tester.widget<Switch>(find.byType(Switch)).value == initialValue,
        maxIterations: 40,
      );
      expect($.tester.widget<Switch>(find.byType(Switch)).value, initialValue);
    },
  );
}
