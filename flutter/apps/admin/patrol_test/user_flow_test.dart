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
import 'package:admin/classes/audit_log_entry.dart';
import 'package:admin/main.dart';
import 'package:admin/screens/audit_log_screen.dart';
import 'package:admin/screens/hospital_management_screen.dart';
import 'package:admin/screens/organization_settings_screen.dart';
import 'package:admin/screens/user_management_screen.dart';
import 'package:admin/widgets/edit_hospital_dialog.dart';
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
    'admin manages a user through its full lifecycle, manages a hospital, toggles every org '
    'setting, and verifies each action\'s audit log entry',
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
      final updatedFirstName = 'PatrolUpdated${DateTime.now().millisecondsSinceEpoch}';

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

      // Edit the profile (user.update) — first name only, so newUserEmail
      // stays valid for every lookup below (the dialog resends its own
      // unchanged email field regardless, so this alone doesn't touch it).
      // Scoped to the dialog's own TextFields, not a bare enterTextAt() —
      // the UserManagementScreen's own Add User form underneath this modal
      // stays mounted with its own 3 TextFields, so a page-global index
      // could hit the wrong field entirely.
      final dialogFirstNameField = find
          .descendant(of: find.byType(EditUserDialog), matching: find.byType(TextField))
          .at(1);
      await $.tester.ensureVisible(dialogFirstNameField);
      await $.tester.enterText(dialogFirstNameField, updatedFirstName);
      await $.pump(const Duration(milliseconds: 400));
      await tapKey($, 'save_profile_button');
      await pumpUntil($, () => find.text('Saved.').evaluate().isNotEmpty, maxIterations: 30);

      // Resend invite (user.resendInvite) — only offered while the account
      // is still passwordless, which it stays for this entire test (this
      // dialog never sets a password for it).
      await tapKey($, 'resend_invite_button');
      await pumpUntil(
        $,
        () => find.text('Invite email resent.').evaluate().isNotEmpty,
        maxIterations: 30,
      );

      // Suspend (user.disable), then reactivate (user.enable) — a real
      // confirmation dialog gates suspending only, not reactivating.
      await tapKey($, 'toggle_disabled_button');
      await pumpUntil($, () => find.text('Suspend account?').evaluate().isNotEmpty);
      await tapFinder($, find.widgetWithText(FilledButton, 'Suspend'));
      await pumpUntil(
        $,
        () => find.text('Account suspended.').evaluate().isNotEmpty,
        maxIterations: 30,
      );
      await tapKey($, 'toggle_disabled_button');
      await pumpUntil(
        $,
        () => find.text('Account reactivated.').evaluate().isNotEmpty,
        maxIterations: 30,
      );

      // Reset MFA (user.resetMfa).
      await tapKey($, 'reset_mfa_button');
      await pumpUntil($, () => find.text('Reset two-step sign-in?').evaluate().isNotEmpty);
      await tapFinder($, find.widgetWithText(FilledButton, 'Reset'));
      await pumpUntil(
        $,
        () => find.text('Two-step sign-in reset.').evaluate().isNotEmpty,
        maxIterations: 30,
      );

      // Delete (user.delete) — last, since nothing below needs this user
      // to still exist. _deleteAccount() closes the dialog itself once the
      // real call succeeds, so there's no separate close step here.
      await tapKey($, 'delete_account_button');
      await pumpUntil($, () => find.text('Delete account?').evaluate().isNotEmpty);
      await tapFinder($, find.widgetWithText(FilledButton, 'Delete'));
      await pumpUntil(
        $,
        () => find.text(newUserEmail).evaluate().isEmpty,
        maxIterations: 50,
      );
      expect(find.text(newUserEmail), findsNothing, reason: 'user should have been deleted');

      // Navigate to Hospitals via the hamburger menu — its own tab again,
      // not folded into Settings (see hospital_management_screen.dart's
      // own doc comment for why).
      await tapIcon($, Icons.menu);
      await tapText($, 'Hospitals');
      await pumpUntil(
        $,
        () => find.byType(HospitalManagementScreen).evaluate().isNotEmpty,
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

      // Edit it (hospital.update) — address only, so hospitalName (and
      // its delete_hospital_$hospitalName key below) stays valid.
      await pumpUntil(
        $,
        () => find.byKey(Key('edit_hospital_$hospitalName')).evaluate().isNotEmpty,
        maxIterations: 20,
      );
      await tapKey($, 'edit_hospital_$hospitalName');
      final dialogAddressField = find
          .descendant(of: find.byType(EditHospitalDialog), matching: find.byType(TextField))
          .at(1);
      await $.tester.ensureVisible(dialogAddressField);
      await $.tester.enterText(dialogAddressField, '123 Main St Unit 5, Toronto, ON');
      await $.pump(const Duration(milliseconds: 400));
      await tapKey($, 'save_hospital_button');
      await pumpUntil($, () => find.text('Saved.').evaluate().isNotEmpty, maxIterations: 30);
      await tapText($, 'Close');
      await $.pump(const Duration(milliseconds: 300));

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

      // Navigate to Settings — hospitals moved out, this is org-level
      // toggles only now.
      await tapIcon($, Icons.menu);
      await tapText($, 'Settings');
      await pumpUntil(
        $,
        () => find.byType(OrganizationSettingsScreen).evaluate().isNotEmpty,
      );

      // Toggle retention (organization.setRetention). Scoped to .first: the
      // Settings page has a Switch per card (Data Retention, Patient
      // Record Audit Logging, Patient Data Encryption, FHIR Data Export) —
      // a bare find.byType(Switch) matches all four, and Data Retention is
      // the first card, so .first is it specifically. The other three now
      // have their own explicit keys instead (added alongside this test),
      // since relying on index gets more fragile as more cards are added.
      final retentionSwitch = find.byType(Switch).first;

      // The Switch's value reflects a live Firestore listener, not local
      // optimistic state (see the screen's own doc comment), so it only
      // flips once the Cloud Function write round trips back through the
      // listener — toggleSwitchAndWait retries the whole tap, not just
      // the wait, since a dropped tap and a slow round trip look
      // identical from here (confirmed for real: this exact toggle
      // occasionally missed a single 16s wait on a loaded dev machine
      // even though the identical tap+wait had just been reliable).
      final initialValue = $.tester.widget<Switch>(retentionSwitch).value;
      await toggleSwitchAndWait($, retentionSwitch);
      expect($.tester.widget<Switch>(retentionSwitch).value, !initialValue);

      // Toggle it back so the org's setting isn't left changed.
      await toggleSwitchAndWait($, retentionSwitch);
      expect($.tester.widget<Switch>(retentionSwitch).value, initialValue);

      // Toggle country (organization.setCountry) — reads the live-prefilled
      // current value rather than assuming a specific starting country,
      // same reasoning as the retention switch's own initialValue read.
      // Selected by key, not by matching the option's display text after
      // opening the dropdown — the currently-selected option's text is
      // already visible in the closed field, so a bare text match risks
      // matching that instead of the freshly-opened menu's copy.
      final countryDropdown = find.byType(DropdownButtonFormField<String>);
      final initialCountry =
          $.tester.widget<DropdownButtonFormField<String>>(countryDropdown).initialValue;
      final nextCountry = initialCountry == 'CA' ? 'US' : 'CA';
      await tapKey($, 'country_dropdown');
      await pumpUntil(
        $,
        () => find.byKey(Key('country_option_$nextCountry')).evaluate().isNotEmpty,
      );
      await tapKey($, 'country_option_$nextCountry');
      await tapKey($, 'save_country_button');
      await pumpUntil($, () => find.text('Saved.').evaluate().isNotEmpty, maxIterations: 30);

      // Toggle it back so the org's setting isn't left changed.
      await tapKey($, 'country_dropdown');
      await pumpUntil(
        $,
        () => find.byKey(Key('country_option_$initialCountry')).evaluate().isNotEmpty,
      );
      await tapKey($, 'country_option_$initialCountry');
      await tapKey($, 'save_country_button');
      await pumpUntil($, () => find.text('Saved.').evaluate().isNotEmpty, maxIterations: 30);

      // Toggle CMEK preference (organization.setCmekPreference).
      final cmekSwitch = find.byKey(const Key('cmek_switch'));
      await toggleSwitchAndWait($, cmekSwitch);
      await toggleSwitchAndWait($, cmekSwitch);

      // Toggle audit logging (organization.setAuditLogging). Safe to flip
      // off and back on mid-test — audit.ts's GATED_ACTIONS only gates
      // patient.* actions; every user.*/hospital.*/organization.* action
      // (including this toggle's own entry) is always logged regardless,
      // precisely so disabling this can't hide the act of disabling it.
      final auditSwitch = find.byKey(const Key('audit_logging_switch'));
      await toggleSwitchAndWait($, auditSwitch);
      await toggleSwitchAndWait($, auditSwitch);

      // Toggle FHIR export (organization.setFhirExportEnabled).
      final fhirSwitch = find.byKey(const Key('fhir_export_switch'));
      await toggleSwitchAndWait($, fhirSwitch);
      await toggleSwitchAndWait($, fhirSwitch);

      // Finally, verify every action above actually produced its audit log
      // entry — the whole point of this extended test. Two verification
      // strengths, matched to what each action's own logAudit call
      // actually records (see functions/src/admin.ts): user.create/update/
      // delete and hospital.create/update/delete carry a readable, this-
      // run-unique identifier (email/firstName/hospitalName) in their
      // Details column, so those are scoped precisely, the same
      // find.descendant(of: Table, ...) discipline as every other
      // assertion in this suite. The role/status/MFA/invite actions and
      // every organization.* toggle carry no per-run-unique detail at all
      // — no target entity to name, or a uid Details never renders — so
      // for those, confirming the correct auditActionLabels text rendered
      // at all is the strongest signal actually available, not a shortcut.
      await tapIcon($, Icons.menu);
      await tapText($, 'Audit Log');
      await pumpUntil(
        $,
        () => find.byType(AuditLogScreen).evaluate().isNotEmpty,
      );

      Finder auditRowContaining(String substring) => find.descendant(
        of: find.byType(Table),
        matching: find.textContaining(substring),
      );
      Finder auditRowWithLabel(String action) => find.descendant(
        of: find.byType(Table),
        matching: find.text(auditActionLabels[action] ?? action),
      );

      for (final substring in [newUserEmail, updatedFirstName, hospitalName]) {
        await pumpUntil(
          $,
          () => auditRowContaining(substring).evaluate().isNotEmpty,
          maxIterations: 40,
        );
        expect(
          auditRowContaining(substring),
          findsWidgets,
          reason: 'audit log should show an entry mentioning "$substring"',
        );
      }

      for (final action in [
        'user.roleAdd',
        'user.roleRemove',
        'user.disable',
        'user.enable',
        'user.resetMfa',
        'user.resendInvite',
        'organization.setRetention',
        'organization.setCountry',
        'organization.setCmekPreference',
        'organization.setAuditLogging',
        'organization.setFhirExportEnabled',
      ]) {
        await pumpUntil(
          $,
          () => auditRowWithLabel(action).evaluate().isNotEmpty,
          maxIterations: 40,
        );
        expect(
          auditRowWithLabel(action),
          findsWidgets,
          reason: '"${auditActionLabels[action]}" should appear in the audit log',
        );
      }
    },
  );
}
