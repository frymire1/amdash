/// Mirrors `libs/auth/src/lib/classes/account-status.ts` — the response
/// shape of the `checkAccountStatus` Cloud Function, driving the
/// email-first login flow's branch (not-activated / set-password / sign-in).
class AccountStatus {
  const AccountStatus({required this.exists, required this.hasPassword});

  factory AccountStatus.fromJson(Map<Object?, Object?> json) {
    return AccountStatus(
      exists: json['exists'] as bool? ?? false,
      hasPassword: json['hasPassword'] as bool? ?? false,
    );
  }

  final bool exists;
  final bool hasPassword;
}
