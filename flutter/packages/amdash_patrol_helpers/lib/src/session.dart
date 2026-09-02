import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'interaction_helpers.dart';

/// Signs in via `LoginScreen`'s own email-then-password flow — shared by
/// every app in this family (admin/ems/physician all use the identical
/// two-step dance: enter email, tap Continue, wait for the Sign In step to
/// appear, enter password, tap Sign In). Only covers signing into an
/// *existing* account with a password already set — first_login_test
/// .dart's own set-password step for a brand-new admin-created account is
/// a genuinely different screen, not something this covers.
Future<void> signIn(PatrolIntegrationTester $, String email, String password) async {
  await enterTextAt($, 0, email);
  await tapText($, 'Continue');
  await pumpUntil($, () => find.text('Sign In').evaluate().isNotEmpty);
  await enterTextAt($, 0, password);
  await tapText($, 'Sign In');
}

/// Signs out via the shared `NavBar`'s own account menu (`amdash_core`'s
/// `nav_bar.dart` — a `PopupMenuButton` tooltipped 'Account', with a
/// 'Logout' item calling `authServiceProvider.signOut()`), then waits for
/// the real round trip back to a fresh `LoginScreen`.
///
/// Only safe to use *within* a single `patrolTest` block, mid-scenario —
/// Patrol's own native test dispatcher does a full page reload between
/// separate `patrolTest` blocks in the same file (confirmed for real: a
/// second block's fresh `pumpWidgetAndSettle` landed back on `LoginScreen`
/// even for an account that had just signed in during the first block),
/// so a signed-in session never actually survives a block boundary to
/// sign out of in the first place. Multiple scenarios that need different
/// accounts belong in one `patrolTest` block together, with this in
/// between them, not in separate blocks — see physician's
/// first_login_test.dart.
///
/// `find.byTooltip('Account')` — not a `Key` — because `NavBar` doesn't
/// have one; this matches the same finder style already used elsewhere in
/// this app family's own widget tests (e.g. physician's
/// patient_viewer_test.dart, ems's patient_upload_screen_test.dart).
/// Waiting for 'Continue' at the end mirrors every other test in this
/// suite's own marker for "freshly on LoginScreen, nobody signed in."
Future<void> signOut(PatrolIntegrationTester $) async {
  await tapFinder($, find.byTooltip('Account'));
  await pumpUntil($, () => find.text('Logout').evaluate().isNotEmpty);
  await tapText($, 'Logout');
  await pumpUntil(
    $,
    () => find.text('Continue').evaluate().isNotEmpty,
    maxIterations: 60,
  );
}
