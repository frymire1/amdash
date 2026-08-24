import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/account_status.dart';

/// Every callable Cloud Function this app hits runs in this region — must
/// match `REGION` in `functions/src/shared.ts`.
const _functionsRegion = 'northamerica-northeast2';

/// Mirrors `libs/auth/src/lib/services/auth.service.ts`: wraps Firebase
/// Auth plus the two public (no-auth-required) callables that drive the
/// email-first login flow. There is no self-registration anywhere in
/// AmDash — every account is admin-created — so this never calls
/// `createUserWithEmailAndPassword` directly; `claimPasswordlessAccount`
/// (via the `setInitialPassword` callable) is the only way a brand-new
/// account gets its first password.
class AuthService {
  AuthService(this._auth, this._functions);

  final FirebaseAuth _auth;
  final FirebaseFunctions _functions;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  bool get isAuthenticated => _auth.currentUser != null;

  Future<AccountStatus> checkAccountStatus(String email) async {
    final callable = _functions.httpsCallable('checkAccountStatus');
    final result = await callable.call<Map<Object?, Object?>>({
      'email': email,
    });
    return AccountStatus.fromJson(result.data);
  }

  Future<UserCredential> signIn(String email, String password) {
    return _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  // Firestore's client SDK caches locally by default — every patient
  // record (vitals, notes, treatment, and more, per the CMEK toggle's own
  // scope) either app has ever read sits in that cache until something
  // clears it, on every device, indefinitely. That cache shouldn't outlive
  // the session that justified it being there, especially on a device
  // shared across shifts (an ambulance tablet). Called from every sign-out
  // path, including IdleTimeoutWrapper's own idle-triggered call to this
  // same method — so the auto-logoff clears it too, not just an explicit
  // sign-out.
  //
  // terminate() first: clearPersistence() throws if any Firestore listener
  // is still open, and this app has several non-autoDispose StreamProviders
  // (userProfileProvider, the patient list providers, EmsLocationController)
  // that don't necessarily tear down the instant sign-out fires — reliably
  // tracking down and cancelling every one of them here isn't realistic.
  // terminate() sidesteps that by forcibly closing every open
  // listener/connection at the SDK level, whatever's holding it. Firestore
  // transparently reconnects on its own next use regardless (e.g. a
  // different worker signing into the same shared device right after), so
  // this doesn't leave the app in any kind of broken state.
  //
  // Best-effort: swallows any failure rather than blocking sign-out on it —
  // this is defense in depth on top of encryption/access control, not the
  // primary goal of signing out.
  Future<void> _clearLocalCache() async {
    try {
      final firestore = FirebaseFirestore.instance;
      await firestore.terminate();
      await firestore.clearPersistence();
    } catch (_) {}
  }

  Future<void> signOut() async {
    await _auth.signOut();
    await _clearLocalCache();
  }

  // Calls the requestPasswordReset callable (functions/src/shared.ts)
  // rather than the Firebase Auth client SDK's own
  // sendPasswordResetEmail — that method both mints the reset link and
  // sends Firebase's own unbranded email for it, with no way to
  // intercept just the delivery. The callable mints the same kind of
  // link via the Admin SDK, then sends a branded email through Resend
  // instead (see email.ts's sendPasswordResetEmail).
  Future<void> resetPassword(String email) async {
    final callable = _functions.httpsCallable('requestPasswordReset');
    await callable.call<Map<Object?, Object?>>({'email': email});
  }

  // Same reasoning as resetPassword above, for email verification: calls
  // the requestEmailVerification callable instead of the signed-in
  // user's own currentUser.sendEmailVerification(), so the email is
  // branded and sent through Resend rather than Firebase's own mailer.
  Future<void> sendEmailVerification() async {
    final callable = _functions.httpsCallable('requestEmailVerification');
    await callable.call<Map<Object?, Object?>>(<String, Object?>{});
  }

  /// For an admin-created account that has no password yet: sets its first
  /// password via the `setInitialPassword` callable (refuses if the
  /// account already has a password credential — see
  /// `functions/src/shared.ts`), then signs in with it.
  Future<UserCredential> claimPasswordlessAccount(
    String email,
    String password,
  ) async {
    final callable = _functions.httpsCallable('setInitialPassword');
    await callable.call<Map<Object?, Object?>>({
      'email': email,
      'password': password,
    });
    return signIn(email, password);
  }
}

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(
    FirebaseAuth.instance,
    FirebaseFunctions.instanceFor(region: _functionsRegion),
  );
});

/// Mirrors `AuthService.initializing`/`user` signals — a stream of the
/// current Firebase Auth user, `null` while signed out. Guard chains
/// (see `guards/`) wait for this provider's first non-loading value the
/// same way the Angular guards wait for `initializing` to settle.
final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(authServiceProvider).authStateChanges;
});
