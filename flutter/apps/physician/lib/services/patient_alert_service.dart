import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Firebase Cloud Messaging Web Push certificate key — a public
/// identifier, not a secret (mirrors `patient-alert.service.ts`'s
/// hardcoded `VAPID_KEY`). Only used on the web target; native platforms
/// (Android/iOS) don't take a vapidKey.
const _vapidKey = 'BOyziwdy1IYAaRdmBO0KZlyCwrRtxPoacISCqUoJiTYPkTpgVAAlAw7ScAVqUC4uCs2JTYn7cifydpr-I1XpGlQ';

/// How long, and how many times, [_ensureApnsTokenReady] polls
/// getAPNSToken() before giving up and calling getToken() anyway. Mirrors
/// ems_alert_service.dart's identical constants.
const _apnsTokenMaxAttempts = 10;
const _apnsTokenRetryDelay = Duration(seconds: 1);

class EnableAlertsResult {
  const EnableAlertsResult({required this.granted});
  final bool granted;
}

/// The real Object thrown by the most recent `enableAlerts` call, if any
/// — same debug-capture rationale as amdash_core's
/// `fhir_export_service.dart`'s `debugLastExportError`: the screen's own
/// catch block (`user_settings_screen.dart`'s `_enableAlerts`) deliberately
/// shows a generic "Failed to enable alerts" message rather than a raw
/// exception, but a test needs the real reason to diagnose a failure it
/// can't otherwise observe (no OS-level notification permission UI is
/// visible to a headless test either way, and console/print isn't a
/// reliable channel back to a test in this pipeline — see
/// `debugLastExportError`'s own doc comment).
Object? debugLastEnableAlertsError;

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
    try {
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        await _recordFailure(uid, 'Notification permission denied (authorizationStatus: ${settings.authorizationStatus}).');
        return const EnableAlertsResult(granted: false);
      }

      await _ensureApnsTokenReady();

      final token = await _messaging.getToken(vapidKey: _vapidKey);
      if (token == null) {
        await _recordFailure(
          uid,
          'getToken() returned null after permission was granted (authorizationStatus: '
          '${settings.authorizationStatus}).',
        );
        return const EnableAlertsResult(granted: false);
      }

      final expiresAt = Timestamp.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch + hours * 3600000,
      );
      await _userProfileService.enableNewPatientAlerts(uid, expiresAt, token, etaAlertThresholdsMinutes);
      return const EnableAlertsResult(granted: true);
    } catch (error) {
      debugLastEnableAlertsError = error;
      await _recordFailure(uid, error.toString());
      rethrow;
    }
  }

  /// Best-effort mirror of *why* enabling didn't end in a token being
  /// written — see UserProfileService.recordFcmRegistrationError's own doc
  /// comment for why this exists at all (debugLastEnableAlertsError
  /// doesn't exist in a real production build, so a real device's silent
  /// failure was otherwise completely unobservable). Never lets a failure
  /// to record a failure escape — a broken diagnostic write shouldn't turn
  /// into a *second*, different exception on top of the real one.
  Future<void> _recordFailure(String uid, String reason) async {
    try {
      await _userProfileService.recordFcmRegistrationError(uid, reason);
    } catch (_) {
      // Best-effort only — see doc comment above.
    }
  }

  /// getToken() needs the native APNs device token to already be
  /// registered — a separate async round trip through Apple's push
  /// servers (`application:didRegisterForRemoteNotificationsWithDeviceToken:`)
  /// that often hasn't finished yet on a fresh cold start right after
  /// permission is granted, and getToken() throws if called before it has.
  /// Mirrors ems_alert_service.dart's identical fix — see that file's own
  /// doc comment for how this was found (a real manual iOS test of the
  /// EMS app's equivalent flow). getAPNSToken() is iOS/macOS-only and
  /// resolves null immediately on every other platform, so this is a
  /// no-op everywhere else.
  Future<void> _ensureApnsTokenReady() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    for (var attempt = 0; attempt < _apnsTokenMaxAttempts; attempt++) {
      if (await _messaging.getAPNSToken() != null) {
        return;
      }
      await Future.delayed(_apnsTokenRetryDelay);
    }
    // Gives up and calls getToken() anyway rather than waiting forever —
    // if it still throws, the catch block above rethrows exactly as
    // before this fix existed, no worse off than the original behavior.
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
