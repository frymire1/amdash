import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otp/otp.dart';
import 'package:patrol/patrol.dart';

import 'interaction_helpers.dart';

/// Every account across this app family requires TOTP MFA (each app's own
/// route guard checks it right after auth) — a freshly created throwaway
/// account has never enrolled, so sign-in always lands on the MFA setup
/// screen first. There's no server-side shortcut: the Admin SDK can only
/// pre-enroll *phone* factors, not TOTP, so this drives the real
/// enrollment UI instead of bypassing it — reads the on-screen secret and
/// computes an actual valid code, exactly like a real authenticator app
/// would. Accounts seeded for these tests are created with
/// `emailVerified: true` already, so MFA setup skips straight to the TOTP
/// step without an email-verification detour.
///
/// Assumes the enrollment screen exposes the secret via a
/// `SelectableText` keyed `mfa_secret_key`, a single `TextField` for the
/// code, and a 'Confirm' button — the shape every app in this family's
/// MFA setup screen already uses (`amdash_core`'s shared
/// `mfa_setup_screen.dart`/`totp_enrollment_form.dart`).
Future<void> completeMfaEnrollment(PatrolIntegrationTester $) async {
  await pumpUntil(
    $,
    () => find.byKey(const Key('mfa_secret_key')).evaluate().isNotEmpty,
    maxIterations: 40,
  );
  final secret = $.tester.widget<SelectableText>(find.byKey(const Key('mfa_secret_key'))).data!;
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
  await enterTextAt($, 0, code);
  await tapText($, 'Confirm');
  await pumpUntil(
    $,
    () => find.byKey(const Key('mfa_secret_key')).evaluate().isEmpty,
    maxIterations: 30,
  );
}
