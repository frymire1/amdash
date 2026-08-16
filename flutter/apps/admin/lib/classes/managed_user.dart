import 'package:amdash_core/amdash_core.dart';

/// Mirrors `ManagedUser` (`functions/src/admin.ts`) — the shape
/// `listUsersWithRoles` returns for each user in the caller's org.
class ManagedUser {
  const ManagedUser({
    required this.uid,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.role,
    required this.disabled,
    required this.hasPassword,
  });

  factory ManagedUser.fromJson(Map<Object?, Object?> json) {
    final rawRoles = json['role'];
    return ManagedUser(
      uid: json['uid'] as String? ?? '',
      email: json['email'] as String? ?? '',
      firstName: json['firstName'] as String? ?? '',
      lastName: json['lastName'] as String? ?? '',
      role: rawRoles is List
          ? rawRoles.whereType<String>().map(UserRole.fromFirestore).whereType<UserRole>().toList()
          : const [],
      // Absent from updateUser's response (it doesn't touch either) — only
      // listUsersWithRoles ever actually populates these, so default to
      // "active" rather than treating a missing field as suspended/pending.
      disabled: json['disabled'] as bool? ?? false,
      hasPassword: json['hasPassword'] as bool? ?? true,
    );
  }

  final String uid;
  final String email;
  final String firstName;
  final String lastName;
  final List<UserRole> role;
  final bool disabled;
  final bool hasPassword;
}

/// Mirrors `ASSIGNABLE_ROLES` (`functions/src/admin.ts`) — an admin can
/// only ever create/assign/remove these three roles, never `admin` or
/// `super-admin` (minted only by `createOrganization`, which requires
/// `super-admin` and is a wholly separate flow).
const assignableRoles = [UserRole.ems, UserRole.physician, UserRole.nurse];
