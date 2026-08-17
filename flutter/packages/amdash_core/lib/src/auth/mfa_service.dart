import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_service.dart';

/// Thrown by [MfaService]'s mutating methods when Firebase refuses an
/// enroll/unenroll because the current session is too old — MFA changes
/// are a "sensitive operation" Firebase Auth guards this way. Callers
/// should prompt for the password again (see `showReauthPasswordDialog`
/// in `widgets/dialogs.dart`), reauthenticate, then retry — this is a real
/// case here, not theoretical: EMS keeps its session alive for a whole
/// shift via `flutter_foreground_task`, so a user routed to `/mfa-setup`
/// (or hitting the self-service re-enroll flow) hours in can plausibly
/// have an old-enough session to trip this.
class MfaRequiresRecentLoginException implements Exception {
  const MfaRequiresRecentLoginException();
}

/// Wraps the TOTP enrollment/unenrollment primitives so `mfa_setup_screen`
/// and the self-service re-enroll widget (`MfaSecurityCard`) share exactly
/// one implementation rather than two independently-maintained copies of
/// security-critical logic.
class MfaService {
  MfaService(this._auth);

  final FirebaseAuth _auth;

  Future<T> _guardRecentLogin<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on FirebaseAuthException catch (error) {
      if (error.code == 'requires-recent-login') {
        throw const MfaRequiresRecentLoginException();
      }
      rethrow;
    }
  }

  Future<void> reauthenticate(String password) {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      throw StateError('No signed-in user with an email to reauthenticate.');
    }
    return user.reauthenticateWithCredential(EmailAuthProvider.credential(email: email, password: password));
  }

  /// Starts a new TOTP enrollment — the returned [TotpSecret] carries both
  /// the QR-code URL (`generateQrCodeUrl`) and the raw secret for manual
  /// entry. Never persisted; the caller holds it in memory only for the
  /// duration of the enrollment sub-flow.
  Future<TotpSecret> beginEnrollment() {
    return _guardRecentLogin(() async {
      final user = _auth.currentUser;
      if (user == null) throw StateError('No signed-in user to enroll MFA for.');
      final session = await user.multiFactor.getSession();
      return TotpMultiFactorGenerator.generateSecret(session);
    });
  }

  /// Completes enrollment — `enroll()` itself is the code-verification
  /// call (a wrong code surfaces as an exception from this, e.g.
  /// `invalid-verification-code`), there's no separate "verify" round
  /// trip. `displayName` is required by the SDK for TOTP factors — always
  /// passed as a fixed literal since this app only ever models exactly one
  /// enrolled factor per account.
  Future<void> confirmEnrollment(TotpSecret secret, String code) {
    return _guardRecentLogin(() async {
      final user = _auth.currentUser;
      if (user == null) throw StateError('No signed-in user to enroll MFA for.');
      final assertion = await TotpMultiFactorGenerator.getAssertionForEnrollment(secret, code);
      await user.multiFactor.enroll(assertion, displayName: 'Authenticator app');
    });
  }

  /// Unenrolls every currently-enrolled TOTP factor — used by the
  /// self-service "change authenticator" flow, always called *before*
  /// starting a fresh enrollment (never after): `enroll()` adds to a list
  /// rather than replacing, so enrolling a second factor without first
  /// removing the old one would leave two enrolled factors and risk a
  /// later sign-in challenge resolving against the now-dead one,
  /// permanently locking the account out of a flow self-service can't
  /// undo. Safe to abandon mid-way — a user left with zero factors just
  /// routes back through mandatory `/mfa-setup` next time, same as a
  /// brand-new account.
  Future<void> unenrollTotp() {
    return _guardRecentLogin(() async {
      final user = _auth.currentUser;
      if (user == null) throw StateError('No signed-in user to unenroll MFA for.');
      final factors = await user.multiFactor.getEnrolledFactors();
      for (final factor in factors.where((f) => f.factorId == 'totp')) {
        await user.multiFactor.unenroll(multiFactorInfo: factor);
      }
    });
  }
}

final mfaServiceProvider = Provider<MfaService>((ref) {
  return MfaService(FirebaseAuth.instance);
});

/// The enrolled-factors list for the current user — the one thing
/// `AppRouteGuard`'s mandatory-MFA tier and admin's `_adminRedirect` both
/// read. `getEnrolledFactors()` is a real async platform-channel call, not
/// a cached field (verified against the installed SDK — there is no
/// synchronous equivalent), so this wraps it in a `FutureProvider` keyed
/// off [authStateProvider] rather than having the guards await it inline
/// on every navigation attempt/`RouterRefreshNotifier` tick. Unlike
/// `userProfileProvider`, there's no live Firestore listener backing
/// this — it's a point-in-time fetch that goes stale the instant
/// enroll()/unenroll() mutates it, so every call site that mutates MFA
/// state must `ref.invalidate(mfaEnrolledFactorsProvider)` immediately
/// after.
final mfaEnrolledFactorsProvider = FutureProvider<List<MultiFactorInfo>>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return const [];
  return user.multiFactor.getEnrolledFactors();
});
