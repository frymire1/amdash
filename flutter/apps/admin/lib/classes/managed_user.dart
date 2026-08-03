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
    );
  }

  final String uid;
  final String email;
  final String firstName;
  final String lastName;
  final List<UserRole> role;
}

/// Mirrors `ASSIGNABLE_ROLES` (`functions/src/admin.ts`) — an admin can
/// only ever create/assign/remove these three roles, never `admin` or
/// `super-admin` (minted only by `createOrganization`, which requires
/// `super-admin` and is a wholly separate flow).
const assignableRoles = [UserRole.ems, UserRole.physician, UserRole.nurse];
