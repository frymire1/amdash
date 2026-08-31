// Phase 3 verification: runs via `patrol test --device chrome` against
// real Chrome, real Firebase Auth/Firestore/Cloud Functions on
// amdash-dev. The throwaway admin account this signs in with is created
// directly via the Firebase Admin SDK, not by this test — pass its
// email/password via --dart-define, same convention as the EMS/physician
// apps' own tests.
//
// tapFinder/tapKey/tapIcon/enterTextAt/pumpUntil/completeMfaEnrollment
// come from amdash_patrol_helpers, shared across every app's
// patrol_test/ suite — see that package for the full rationale/history
// behind each one.
import 'package:admin/main.dart';
import 'package:admin/screens/organization_settings_screen.dart';
import 'package:admin/screens/user_management_screen.dart';
import 'package:admin/widgets/edit_user_dialog.dart';
import 'package:amdash_patrol_helpers/amdash_patrol_helpers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:admin/firebase_options.dart';

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
      // Scoped to the users Table, not a bare find.text(newUserEmail) — on
      // success, _createUser doesn't clear the form's own Email field
      // until *after* the real createUser call returns, so a bare
      // find.text() can match that still-filled TextField instead of a
      // genuine new row. Same class of bug, same fix, as this file's own
      // hospital-creation assertion below ("Confirmed via a real GHA
      // failure ('Found 2 widgets')") — confirmed for real this time too,
      // running admin/patrol_test/create_user_test.dart's identical
      // unscoped version locally: it reported success while createUser
      // had actually thrown, the email field was simply never cleared,
      // and no account existed afterward. The edit_user_$newUserEmail
      // wait right below this would likely still have caught a genuinely
      // failed creation eventually — this was never a silent full-test
      // false pass — but the assertion itself wasn't proving what its own
      // reason string claimed either.
      final userRow = find.descendant(of: find.byType(Table), matching: find.text(newUserEmail));
      await pumpUntil($, () => userRow.evaluate().isNotEmpty);
      expect(
        userRow,
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
      // Scoped to the hospitals Table, not a bare find.text(hospitalName)
      // — the Add Hospital form's own Name field doesn't clear until
      // _createHospital() actually succeeds, so for a moment both the
      // still-filled TextField (an EditableText, which find.text() also
      // matches) and the new table row show the same text. Confirmed via
      // a real GHA failure ("Found 2 widgets").
      final hospitalRow = find.descendant(
        of: find.byType(Table),
        matching: find.text(hospitalName),
      );
      await pumpUntil(
        $,
        () => hospitalRow.evaluate().isNotEmpty,
        maxIterations: 60,
      );
      expect(
        hospitalRow,
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

      // Still on Settings — toggle retention. Scoped to .first: the
      // Settings page has grown a Switch per card since this was written
      // (Data Retention, Patient Record Audit Logging, Patient Data
      // Encryption) — a bare find.byType(Switch) now matches all three,
      // and Data Retention is the first card, so .first is it specifically.
      final retentionSwitch = find.byType(Switch).first;

      // The Switch's value reflects a live Firestore listener, not local
      // optimistic state (see the screen's own doc comment), so it only
      // flips once the Cloud Function write round trips back through the
      // listener — a flat pump isn't a reliable wait for that, poll for it.
      final initialValue = $.tester.widget<Switch>(retentionSwitch).value;
      await tapFinder($, retentionSwitch);
      await pumpUntil(
        $,
        () => $.tester.widget<Switch>(retentionSwitch).value != initialValue,
        maxIterations: 40,
      );
      expect($.tester.widget<Switch>(retentionSwitch).value, !initialValue);

      // Toggle it back so the org's setting isn't left changed.
      await tapFinder($, retentionSwitch);
      await pumpUntil(
        $,
        () => $.tester.widget<Switch>(retentionSwitch).value == initialValue,
        maxIterations: 40,
      );
      expect($.tester.widget<Switch>(retentionSwitch).value, initialValue);
    },
  );
}
