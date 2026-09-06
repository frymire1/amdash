import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Same public Web Push certificate key physician's own
/// `patient_alert_service.dart` uses — see that file's identical comment:
/// a public identifier, not a secret, one per Firebase project (not one
/// per app). Only used on the web target; native platforms don't take a
/// vapidKey.
const _vapidKey = 'BOyziwdy1IYAaRdmBO0KZlyCwrRtxPoacISCqUoJiTYPkTpgVAAlAw7ScAVqUC4uCs2JTYn7cifydpr-I1XpGlQ';

/// How long, and how many times, [_ensureApnsTokenReady] polls
/// getAPNSToken() before giving up and calling getToken() anyway.
const _apnsTokenMaxAttempts = 10;
const _apnsTokenRetryDelay = Duration(seconds: 1);

/// The real Object thrown by the most recent
/// [EmsAlertService.registerForConnectivityAlerts] call, if any — same
/// debug-capture rationale as physician's own `debugLastEnableAlertsError`
/// (see that file's doc comment): the real call site swallows this (a
/// failed registration shouldn't block sign-in — see this method's own
/// doc comment), so a test needs another way to see the real underlying
/// reason.
Object? debugLastRegisterForConnectivityAlertsError;

/// Set `true` once the most recent [EmsAlertService.registerForConnectivityAlerts]
/// call has fully finished (success or a swallowed failure) — `false` while
/// one is still in flight. `HomeScreen`'s own call site is fire-and-forget
/// (`unawaited`), so a same-process Patrol e2e test (`first_login_test.dart`)
/// has no other way to know the real requestPermission -> getToken ->
/// Firestore-write chain has actually completed before it goes on to check
/// real backend state, rather than racing it. Same in-process debug-capture
/// pattern as [debugLastRegisterForConnectivityAlertsError] itself and
/// `amdash_core`'s `debugLastExportResult`/`debugLastExportError` (already
/// read directly by `ems_test.dart` the same way).
bool debugLastRegisterForConnectivityAlertsFinished = false;

/// EMS's own push-notification registration, for
/// `functions/src/ems.ts`'s connectivity-loss alerts (`checkEmsConnectivity`/
/// the explicit-opt-out hook in `onEmsLocationEvent`). Mirrors physician's
/// `PatientAlertService` in shape (the same requestPermission -> getToken
/// -> write-to-`fcmTokens` flow) but simpler: no expiry, no threshold
/// preferences, no separate enable/disable pair — EMS's connectivity-loss
/// alerts are a safety net, not a preference, so every EMS account gets
/// registered automatically, once per session (see `HomeScreen`'s own call
/// site), rather than needing a Settings toggle the way physician's
/// proximity alerts do.
///
/// Lives here, not in `amdash_core`, for the same reason
/// `PatientAlertService` does — `firebase_messaging` pulls in real native
/// push-notification setup (APNs/FCM entitlements) that only the apps
/// actually using it should carry (admin has no reason to).
class EmsAlertService {
  EmsAlertService(this._messaging, this._userProfileService);

  final FirebaseMessaging _messaging;
  final UserProfileService _userProfileService;

  /// Requests notification permission and, if granted, registers this
  /// device's FCM token against [uid]. Deliberately swallows any failure
  /// rather than rethrowing (unlike `PatientAlertService.enableAlerts`,
  /// whose caller shows an error dialog for it) — this runs unprompted
  /// right after sign-in, and a paramedic should never be blocked from
  /// using the app because a push-notification permission prompt was
  /// dismissed or a token fetch failed. `registerFcmToken`'s own
  /// `arrayUnion` write is idempotent, so calling this more than once per
  /// real session (e.g. `HomeScreen` remounting after in-app navigation)
  /// is harmless — no separate "already registered this session" guard
  /// needed.
  Future<void> registerForConnectivityAlerts(String uid) async {
    debugLastRegisterForConnectivityAlertsFinished = false;
    try {
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        await _recordFailure(uid, 'Notification permission denied (authorizationStatus: ${settings.authorizationStatus}).');
        return;
      }

      await _ensureApnsTokenReady();

      final token = await _messaging.getToken(vapidKey: _vapidKey);
      if (token == null) {
        await _recordFailure(
          uid,
          'getToken() returned null after permission was granted (authorizationStatus: '
          '${settings.authorizationStatus}).',
        );
        return;
      }

      await _userProfileService.registerFcmToken(uid, token);
    } catch (error) {
      debugLastRegisterForConnectivityAlertsError = error;
      // Deliberately not rethrown — see this method's own doc comment.
      await _recordFailure(uid, error.toString());
    } finally {
      debugLastRegisterForConnectivityAlertsFinished = true;
    }
  }

  /// Best-effort mirror of *why* registration didn't end in a token being
  /// written — see UserProfileService.recordFcmRegistrationError's own doc
  /// comment for why this exists at all (debugLastRegisterForConnectivityAlertsError
  /// doesn't exist in a real production build, so a real device's silent
  /// failure was otherwise completely unobservable). Never lets a failure
  /// to record a failure escape — that would defeat this method's own
  /// "never blocks sign-in" contract just as surely as rethrowing the
  /// original error would.
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
  /// Confirmed for real: a manual iOS test granted permission and reached
  /// this call, but no token was ever written to Firestore — the resulting
  /// exception was silently swallowed by the catch block above (by design,
  /// per this method's own doc comment), leaving zero visible symptom.
  /// getAPNSToken() is iOS/macOS-only and resolves null immediately on
  /// every other platform, so this is a no-op everywhere else.
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
    // if it still throws, the catch block above swallows it exactly as
    // before this fix existed, no worse off than the original behavior.
  }
}

// A local seam (not amdash_core's firebase_providers.dart) — same
// rationale as physician's own identical firebaseMessagingProvider:
// FirebaseMessaging.instance can't be swapped by a test directly, and
// firebase_messaging deliberately isn't a shared-package dependency (see
// this file's own header comment). Not private: a test needs to override
// it, same as every other seam in this repo.
final firebaseMessagingProvider = Provider<FirebaseMessaging>((ref) => FirebaseMessaging.instance);

final emsAlertServiceProvider = Provider<EmsAlertService>((ref) {
  return EmsAlertService(ref.watch(firebaseMessagingProvider), ref.watch(userProfileServiceProvider));
});
