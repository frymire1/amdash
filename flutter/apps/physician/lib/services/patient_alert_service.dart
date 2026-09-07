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

/// How long, and how many times, [_getTokenWaitingForApns] retries
/// getToken() on an apns-token-not-set error before giving up and letting
/// a final attempt's outcome stand as-is. Mirrors ems_alert_service.dart's
/// identical constants (see that file's own doc comment for why this was
/// bumped up from an earlier, smaller budget).
const _apnsTokenMaxAttempts = 20;
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
    // Written unconditionally, before anything below that could ever hang
    // rather than merely fail — see ems_alert_service.dart's identical
    // write for the full rationale (found chasing the same real-device
    // investigation this mirrors).
    await _recordFailure(uid, 'Registration attempt started but has not yet reached an outcome.');
    try {
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        await _recordFailure(uid, 'Notification permission denied (authorizationStatus: ${settings.authorizationStatus}).');
        return const EnableAlertsResult(granted: false);
      }

      await _reregisterForRemoteNotifications();

      final token = await _getTokenWaitingForApns();
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

  /// registerForRemoteNotifications() only otherwise fires once,
  /// automatically, at app launch — before this method's own
  /// requestPermission() call above has ever had a chance to grant
  /// anything. Mirrors ems_alert_service.dart's identical fix — see that
  /// file's own doc comment for the full story (found by reading
  /// FLTFirebaseMessagingPlugin.m's requestPermission implementation
  /// directly: it never re-triggers registerForRemoteNotifications after
  /// a fresh grant). Toggling setAutoInitEnabled off then back on
  /// re-triggers it as a documented side effect — the closest thing to a
  /// manual trigger this plugin's public API offers.
  Future<void> _reregisterForRemoteNotifications() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    await _messaging.setAutoInitEnabled(false);
    await _messaging.setAutoInitEnabled(true);
  }

  /// getToken() needs the native APNs device token to already be
  /// registered — a separate async round trip through Apple's push
  /// servers (`application:didRegisterForRemoteNotificationsWithDeviceToken:`)
  /// that often hasn't finished yet on a fresh cold start right after
  /// permission is granted. While it hasn't, getToken() throws a
  /// FirebaseException (`apns-token-not-set`) rather than merely returning
  /// null. Mirrors ems_alert_service.dart's identical fix — see that
  /// file's own doc comment for the full story (an earlier version of
  /// this instead polled getAPNSToken() separately as a pre-check,
  /// assuming *it* would return null while pending and that getToken()
  /// would then reliably succeed once it stopped — confirmed for real,
  /// twice, that neither assumption holds). Retrying getToken() itself
  /// directly targets the call that actually needs to succeed. iOS-only:
  /// on every other platform this makes exactly one call, exactly like a
  /// plain `_messaging.getToken(vapidKey: _vapidKey)` would.
  Future<String?> _getTokenWaitingForApns() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return _messaging.getToken(vapidKey: _vapidKey);
    }
    for (var attempt = 1; attempt < _apnsTokenMaxAttempts; attempt++) {
      try {
        return await _messaging.getToken(vapidKey: _vapidKey);
      } on FirebaseException catch (error) {
        if (error.code != 'apns-token-not-set') rethrow;
      }
      await Future.delayed(_apnsTokenRetryDelay);
    }
    // Final attempt: stop waiting and just try — its outcome (a token, or
    // a real throw) propagates normally, same "don't wait forever"
    // philosophy as before, now on the call that's actually the one that
    // needs to succeed.
    return _messaging.getToken(vapidKey: _vapidKey);
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
