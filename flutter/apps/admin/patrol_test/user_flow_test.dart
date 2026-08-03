// Phase 3 verification: runs via `patrol test --device chrome` against
// real Chrome, real Firebase Auth/Firestore/Cloud Functions on
// amdash-dev. The throwaway admin account this signs in with is created
// directly via the Firebase Admin SDK, not by this test — pass its
// email/password via --dart-define, same convention as the EMS/physician
// apps' own tests.
import 'package:admin/main.dart';
import 'package:admin/screens/hospital_management_screen.dart';
import 'package:admin/screens/organization_settings_screen.dart';
import 'package:admin/screens/user_management_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
  // enough that later controls — e.g. the "Assign Role" button — end up
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

Future<void> tapKey(PatrolIntegrationTester $, String key) => tapFinder($, find.byKey(Key(key)));

Future<void> tapText(PatrolIntegrationTester $, String text) => tapFinder($, find.text(text));

Future<void> tapIcon(PatrolIntegrationTester $, IconData icon) => tapFinder($, find.byIcon(icon).first);

/// Polls with fixed pumps rather than a one-shot wait — network round
/// trips (Cloud Function calls + Firestore listener updates) don't always
/// land inside a short fixed pump.
Future<void> pumpUntil(PatrolIntegrationTester $, bool Function() condition, {int maxIterations = 50}) async {
  for (var i = 0; i < maxIterations; i++) {
    if (condition()) return;
    await $.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  patrolTest(
    'admin creates a user, assigns/removes a role, manages a hospital, and toggles retention',
    ($) async {
      const email = String.fromEnvironment('SMOKE_EMAIL');
      const password = String.fromEnvironment('SMOKE_PASSWORD');
      expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
      expect(password, isNotEmpty, reason: 'pass --dart-define=SMOKE_PASSWORD=...');

      final newUserEmail = 'patrol-created-${DateTime.now().millisecondsSinceEpoch}@amdash-e2e.test';
      final hospitalName = 'Patrol Test Hospital ${DateTime.now().millisecondsSinceEpoch}';

      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      await $.pumpWidgetAndSettle(const ProviderScope(child: AdminApp()));

      // Sign in.
      await $(TextField).at(0).enterText(email);
      await tapText($, 'Continue');
      await pumpUntil($, () => find.text('Sign In').evaluate().isNotEmpty);

      await $(TextField).at(0).enterText(password);
      await tapText($, 'Sign In');

      // Landing redirect sends an admin to /users.
      await pumpUntil(
        $,
        () => find.byType(UserManagementScreen).evaluate().isNotEmpty,
        maxIterations: 50,
      );
      expect(find.byType(UserManagementScreen), findsOneWidget, reason: 'should have reached the main view');

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
      expect(find.text(newUserEmail), findsOneWidget, reason: 'user should have been created within the wait budget');

      // Assign a second role (physician) to the same user. Verified
      // manually against a real browser that this exact flow works
      // correctly. Debug prints proved onChanged fires (role IS set to
      // physician) and the button is found + enabled at tap time, yet
      // neither plain find.text('Assign Role').tap() nor an
      // ancestor-of-text FilledButton tap ever invoked
      // _assignRoleSubmit — but every key-based tap in this whole test
      // has been 100% reliable, so key the submit buttons directly
      // instead of relying on their text.
      await $(TextField).at(3).enterText(newUserEmail);
      await tapKey($, 'assign_role_dropdown');
      await tapKey($, 'assign_role_option_physician');
      await tapKey($, 'assign_role_submit');
      await pumpUntil($, () => find.text('Role assigned.').evaluate().isNotEmpty, maxIterations: 60);
      expect(
        find.text('Role assigned.'),
        findsOneWidget,
        reason: 'role assignment should have succeeded within the wait budget',
      );

      // Remove a role via its chip's close button. Not scoped to our own
      // user's row specifically (Table rows aren't independently
      // findable ancestors) — this only proves the remove action itself
      // completes without error, against test-org's throwaway data.
      //
      // "Role assigned." is set before _assignRoleSubmit awaits its own
      // _refreshUsers() call, and _refreshUsers() immediately flips
      // _loadingUsers = true — which swaps the whole table (every close
      // icon included) for a spinner until that refresh resolves. So the
      // message can appear while the table is mid-reload; wait for a
      // close icon to actually exist before tapping one.
      await pumpUntil($, () => find.byIcon(Icons.close).evaluate().isNotEmpty, maxIterations: 40);
      await tapIcon($, Icons.close);
      await $.pump(const Duration(seconds: 2));

      // Navigate to Hospitals via the hamburger menu.
      await tapIcon($, Icons.menu);
      await tapText($, 'Hospitals');
      await pumpUntil($, () => find.byType(HospitalManagementScreen).evaluate().isNotEmpty);

      // Create a hospital. createHospital calls out to Google's
      // Geocoding API server-side (plus a possible Cloud Function cold
      // start), so this gets a longer budget than the Firestore-only
      // writes above.
      await $(TextField).at(0).enterText(hospitalName);
      await $(TextField).at(1).enterText('123 Main St, Toronto, ON');
      await tapKey($, 'add_hospital_submit');
      await pumpUntil($, () => find.text(hospitalName).evaluate().isNotEmpty, maxIterations: 60);
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
      await pumpUntil($, () => find.byKey(Key('delete_hospital_$hospitalName')).evaluate().isNotEmpty, maxIterations: 20);
      await tapKey($, 'delete_hospital_$hospitalName');
      await pumpUntil($, () => find.text(hospitalName).evaluate().isEmpty, maxIterations: 50);
      expect(find.text(hospitalName), findsNothing);

      // Navigate to Settings via the hamburger menu and toggle retention.
      await tapIcon($, Icons.menu);
      await tapText($, 'Settings');
      await pumpUntil($, () => find.byType(OrganizationSettingsScreen).evaluate().isNotEmpty);

      // The Switch's value reflects a live Firestore listener, not local
      // optimistic state (see the screen's own doc comment), so it only
      // flips once the Cloud Function write round trips back through the
      // listener — a flat pump isn't a reliable wait for that, poll for it.
      final initialValue = $.tester.widget<Switch>(find.byType(Switch)).value;
      await tapFinder($, find.byType(Switch));
      await pumpUntil($, () => $.tester.widget<Switch>(find.byType(Switch)).value != initialValue, maxIterations: 40);
      expect($.tester.widget<Switch>(find.byType(Switch)).value, !initialValue);

      // Toggle it back so the org's setting isn't left changed.
      await tapFinder($, find.byType(Switch));
      await pumpUntil($, () => $.tester.widget<Switch>(find.byType(Switch)).value == initialValue, maxIterations: 40);
      expect($.tester.widget<Switch>(find.byType(Switch)).value, initialValue);
    },
  );
}
