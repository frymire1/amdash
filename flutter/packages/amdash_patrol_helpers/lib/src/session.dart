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

// A signOut() helper used to live here, for merging multiple
// different-account scenarios into one patrolTest block (sign in as A, do
// A's scenario, sign out, sign in as B, do B's scenario). Removed — a real
// attempt at exactly that (physician's first_login_test.dart, briefly)
// found it doesn't work: AuthService.signOut() (amdash_core) deliberately
// calls FirebaseFirestore.terminate() + a full page reload on web, and any
// reload mid-patrolTest kills the currently-running test outright
// (confirmed for real: `FirebaseError: [code=failed-precondition]: The
// client has already been terminated`, the same class of failure Patrol's
// own reload *between* separate patrolTest blocks causes). See
// run-physician-app-redirect-e2e.mjs's own header comment for the fuller
// account. Scenarios needing different accounts stay in separate sessions
// (separate scripts/CI steps, or ordered so the unauthenticated-required
// one runs before any sign-in ever happens and nothing needs to reverse
// it) — never by signing out mid-test.
