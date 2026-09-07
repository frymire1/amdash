import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Same public Web Push certificate key physician's own
/// `patient_alert_service.dart` uses — see that file's identical comment:
/// a public identifier, not a secret, one per Firebase project (not one
/// per app). Only used on the web target; native platforms don't take a
/// vapidKey.
const _vapidKey = 'BOyziwdy1IYAaRdmBO0KZlyCwrRtxPoacISCqUoJiTYPkTpgVAAlAw7ScAVqUC4uCs2JTYn7cifydpr-I1XpGlQ';

/// How long, and how many times, [_getTokenWaitingForApns] retries
/// getToken() on an apns-token-not-set error before giving up and letting
/// a final attempt's outcome (success or a real throw) stand as-is. 20
/// attempts (~20s worst case) — bumped up from an earlier, smaller budget
/// once that one was confirmed for real (via a second real-device test,
/// after the first fix had already shipped) to still not always be
/// enough. Runs unattended in the background either way (see
/// registerForConnectivityAlerts' own `unawaited` call site), so a longer
/// worst case costs nothing visible.
const _apnsTokenMaxAttempts = 20;
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
    // Written unconditionally, before anything below that could ever hang
    // rather than merely fail — every other line in this method already
    // ends in a write to Firestore, on every path, once reached (success
    // clears this; any denial/null-token/exception overwrites it with a
    // more specific reason). If a real device ever shows *only* this
    // message and nothing more specific, that pins the native
    // requestPermission()/getToken() call itself as the thing that never
    // returned at all (a real, if rare, class of iOS plugin-delegate bug),
    // not merely one that failed — a distinction nothing else here could
    // otherwise ever surface.
    await _recordFailure(uid, 'Registration attempt started but has not yet reached an outcome.');
    try {
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        await _recordFailure(uid, 'Notification permission denied (authorizationStatus: ${settings.authorizationStatus}).');
        return;
      }

      await _reregisterForRemoteNotifications();

      final token = await _getTokenWaitingForApns();
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

  /// registerForRemoteNotifications() — the actual native call that asks
  /// Apple for a device token — only otherwise fires once, automatically,
  /// at app launch (as part of firebase_messaging's own plugin
  /// registration), which necessarily happens *before* this method's own
  /// requestPermission() call above has ever had a chance to grant
  /// anything — no app has notification permission before its own launch
  /// finishes. Nothing in the plugin re-triggers that call later once
  /// permission is actually granted (confirmed by reading
  /// FLTFirebaseMessagingPlugin.m's requestPermission implementation
  /// directly: it only calls requestAuthorizationWithOptions, never
  /// registerForRemoteNotifications). If Apple didn't hand over a token
  /// during that first, pre-permission attempt, nothing ever asks again —
  /// a real, previously-unconsidered explanation for a real device's
  /// registration staying permanently stuck on
  /// [firebase_messaging/apns-token-not-set], unmoved by every other fix
  /// tried (retry timing, the AppDelegate delegate cleanup, the
  /// sandbox/production entitlement fix, even a full device restart).
  ///
  /// firebase_messaging exposes no direct Dart-level
  /// "registerForRemoteNotifications now" call, but toggling
  /// setAutoInitEnabled off then back on re-triggers it as a documented
  /// side effect (see messagingSetAutoInitEnabled: in
  /// FLTFirebaseMessagingPlugin.m, which calls
  /// registerForRemoteNotifications() + ensureAPNSTokenSetting()
  /// whenever re-enabled) — the closest thing to a manual trigger this
  /// plugin's public API offers. iOS-only: Android's FCM token doesn't
  /// have this same registration-must-happen-after-permission gap (see
  /// _getTokenWaitingForApns' own doc comment for why this whole APNs
  /// dance is iOS-specific to begin with), so this would just be a
  /// pointless round trip through a platform channel on every other
  /// platform.
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
  /// null. Confirmed for real, twice now: first via a manual iOS test
  /// whose registration silently vanished entirely (an earlier version of
  /// this fix instead polled getAPNSToken() separately as a pre-check,
  /// assuming *it* would return null — not throw — while pending, and
  /// that once it stopped throwing, getToken() would then reliably
  /// succeed); then, after that shipped, a second real-device test still
  /// hit this identical error via lastFcmRegistrationError — getAPNSToken()
  /// throws the same error rather than returning null, *and* even once
  /// that fix silently absorbed those throws and gave up after its own
  /// budget, the subsequent getToken() call still failed the same way.
  /// The two calls' readiness doesn't reliably agree, so polling
  /// getAPNSToken() as a proxy for getToken()'s own readiness doesn't
  /// actually work — retrying getToken() itself, on this exact error
  /// code, directly targets the one call that actually needs to succeed.
  /// iOS-only: this error code is specific to the APNs handshake, so on
  /// every other platform this makes exactly one call, exactly like a
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
