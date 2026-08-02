import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'user_profile_service.dart';

/// The Firebase Cloud Messaging Web Push certificate key — a public
/// identifier, not a secret (mirrors `patient-alert.service.ts`'s
/// hardcoded `VAPID_KEY`). Only used on the web target; native platforms
/// (Android/iOS) don't take a vapidKey.
const _vapidKey = 'BOyziwdy1IYAaRdmBO0KZlyCwrRtxPoacISCqUoJiTYPkTpgVAAlAw7ScAVqUC4uCs2JTYn7cifydpr-I1XpGlQ';

class EnableAlertsResult {
  const EnableAlertsResult({required this.granted});
  final bool granted;
}

/// Mirrors `libs/auth/src/lib/services/patient-alert.service.ts`: arms/
/// disarms new-patient push alerts by requesting notification permission,
/// registering an FCM token, and writing it to the same
/// `fcmTokens`/`newPatientAlertsExpiresAt` fields `sendNewPatientAlerts`
/// (Cloud Function, unchanged) already reads — no server-side change
/// needed for this to work from Flutter.
class PatientAlertService {
  PatientAlertService(this._messaging, this._userProfileService);

  final FirebaseMessaging _messaging;
  final UserProfileService _userProfileService;

  Future<EnableAlertsResult> enableAlerts(String uid, int hours) async {
    final settings = await _messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      return const EnableAlertsResult(granted: false);
    }

    final token = await _messaging.getToken(vapidKey: _vapidKey);
    if (token == null) {
      return const EnableAlertsResult(granted: false);
    }

    final expiresAt = Timestamp.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch + hours * 3600000,
    );
    await _userProfileService.enableNewPatientAlerts(uid, expiresAt, token);
    return const EnableAlertsResult(granted: true);
  }

  Future<void> disableAlerts(String uid) {
    return _userProfileService.disableNewPatientAlerts(uid);
  }
}

final patientAlertServiceProvider = Provider<PatientAlertService>((ref) {
  return PatientAlertService(FirebaseMessaging.instance, ref.watch(userProfileServiceProvider));
});
