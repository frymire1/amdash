import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'interaction_helpers.dart';

/// Fills and submits the mandatory Ambulance ID prompt
/// (ems/lib/screens/ambulance_id_screen.dart) if it's showing — a no-op
/// otherwise. EMS-only (no other app in this family has this screen), but
/// lives here rather than duplicated per test file since every EMS
/// sign-in flow (ems_test.dart, background_gps_tracking_test.dart,
/// first_login_test.dart, patient_upload_flow_test.dart) needs it
/// identically.
///
/// Fills the phone number field too — it became a second required field
/// on this same form alongside the Ambulance ID. Without it, `_submit()`
/// no-ops entirely (both fields must be valid to proceed), so the wait
/// loop below would exhaust its iterations with the prompt still showing
/// and every caller would then fail confusingly on whatever HomeScreen
/// element it looks for next — exactly the failure shape this helper's
/// own history (below) already describes for a different cause.
///
/// Every one of those must call this right after signing in (and, for a
/// first-ever sign-in, right after MFA enrollment), before assuming the
/// next screen is HomeScreen: AmbulanceIdGuard (ems/lib/router.dart)
/// intercepts any account/device with no ambulance ID saved yet, for any
/// org with enableMultipleAmbulanceView on — a real, deterministic
/// redirect once its own async providers (ownOrganizationProvider,
/// ambulanceIdProvider) resolve, not flakiness. Confirmed as the real
/// cause of a whole batch of EMS e2e failures (2026-09-24 CI, ems_test/
/// background_gps_tracking_test both failing right after sign-in) once
/// test-org — the shared account every one of these scripts signs into —
/// had enableMultipleAmbulanceView switched on for the first time:
/// AppRouteGuard's own redirect can briefly land on HomeScreen *before*
/// those two providers finish resolving (both return null — "don't
/// redirect yet" — while still loading), only for AmbulanceIdGuard to
/// yank the app back to `/ambulance-id` moments later once they do. A
/// test that raced into that window got different symptoms depending on
/// exactly when the yank landed — "Add Patient" never found at all
/// (background_gps_tracking_test.dart) vs. mid-form when the field count
/// suddenly dropped from 4 to AmbulanceIdScreen's own 1
/// (ems_test.dart's `TextField.at(2)` RangeError) — same root cause,
/// different snapshots of the same race. Waiting here, before ever
/// touching a HomeScreen-only element, closes that window instead of
/// leaving each caller to rediscover it independently.
Future<void> settleAmbulanceIdPrompt(
  PatrolIntegrationTester $, {
  String ambulanceId = 'Patrol Test Ambulance',
  String phoneNumber = '555-0100',
}) async {
  final field = find.byKey(const Key('ambulance_id_field'));
  // Bounded either way: the field either appears once
  // ownOrganizationProvider/ambulanceIdProvider/ambulancePhoneProvider
  // settle (a live Firestore read, so allow real network time) or never
  // appears at all (the org's flag is off, or this device already has
  // both an ambulance ID and phone number saved) — there's no third,
  // slower-but-still-coming case to wait even longer for.
  await pumpUntil($, () => field.evaluate().isNotEmpty, maxIterations: 30);
  if (field.evaluate().isEmpty) return;

  await enterTextAt($, 0, ambulanceId);
  await enterTextAt($, 1, phoneNumber);
  await tapKey($, 'ambulance_id_submit');
  await pumpUntil($, () => field.evaluate().isEmpty, maxIterations: 30);
}
