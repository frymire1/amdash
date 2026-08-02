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

  Future<void> signOut() => _auth.signOut();

  Future<void> resetPassword(String email) {
    return _auth.sendPasswordResetEmail(email: email);
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
