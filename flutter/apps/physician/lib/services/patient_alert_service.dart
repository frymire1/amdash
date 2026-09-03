import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// disarms patient-arrival push alerts by requesting notification
/// permission, registering an FCM token, and writing it (plus the
/// physician's chosen proximity thresholds) to the `fcmTokens`/
/// `newPatientAlertsExpiresAt`/`etaAlertThresholdsMinutes` fields
/// `notifyPatientProximity` (`functions/src/physician.ts`, triggered from
/// `ems.ts`'s `onEmsLocationEvent`) reads.
///
/// Lives here in the physician app rather than in `amdash_core` — this is
/// the only app that ever arms new-patient alerts (EMS uploads patients,
/// it doesn't need to be told about new ones; admin has no reason to be
/// notified either), and `firebase_messaging` pulls in real native
/// push-notification setup on mobile (APNs/FCM entitlements) — overhead
/// EMS/admin were carrying for zero actual use while this lived in the
/// shared package.
class PatientAlertService {
  PatientAlertService(this._messaging, this._userProfileService);

  final FirebaseMessaging _messaging;
  final UserProfileService _userProfileService;

  Future<EnableAlertsResult> enableAlerts(
    String uid,
    int hours, {
    List<int> etaAlertThresholdsMinutes = const [],
  }) async {
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
    await _userProfileService.enableNewPatientAlerts(uid, expiresAt, token, etaAlertThresholdsMinutes);
    return const EnableAlertsResult(granted: true);
  }

  Future<void> disableAlerts(String uid) {
    return _userProfileService.disableNewPatientAlerts(uid);
  }
}

// A local seam (not amdash_core's firebase_providers.dart — see this
// file's own doc comment for why firebase_messaging deliberately isn't a
// shared-package dependency) — same testability rationale as every seam
// there: FirebaseMessaging.instance can't be swapped by a test directly.
// Not private: a test needs to override it, same as every other seam in
// this repo.
final firebaseMessagingProvider = Provider<FirebaseMessaging>((ref) => FirebaseMessaging.instance);

final patientAlertServiceProvider = Provider<PatientAlertService>((ref) {
  return PatientAlertService(ref.watch(firebaseMessagingProvider), ref.watch(userProfileServiceProvider));
});
