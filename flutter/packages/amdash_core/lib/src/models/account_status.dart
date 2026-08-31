import 'user_profile.dart';

/// Mirrors `libs/auth/src/lib/classes/account-status.ts` — the response
/// shape of the `checkAccountStatus` Cloud Function, driving the
/// email-first login flow's branch (not-activated / wrong-app / set-password
/// / sign-in).
class AccountStatus {
  const AccountStatus({
    required this.exists,
    required this.hasPassword,
    required this.roleAllowed,
    required this.role,
  });

  factory AccountStatus.fromJson(Map<Object?, Object?> json) {
    final rawRole = json['role'];
    return AccountStatus(
      exists: json['exists'] as bool? ?? false,
      hasPassword: json['hasPassword'] as bool? ?? false,
      // Defaults to true, not false — a server response that's somehow
      // missing this field (an old cached function version mid-deploy,
      // say) should never lock every caller out; that's what actually
      // requesting a role check and getting `false` back is for.
      roleAllowed: json['roleAllowed'] as bool? ?? true,
      role: rawRole is List
          ? rawRole
              .whereType<String>()
              .map(UserRole.fromFirestore)
              .whereType<UserRole>()
              .toList()
          : const [],
    );
  }

  final bool exists;
  final bool hasPassword;
  final bool roleAllowed;
  final List<UserRole> role;
}
