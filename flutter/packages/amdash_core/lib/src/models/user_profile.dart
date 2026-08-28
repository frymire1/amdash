import 'package:cloud_firestore/cloud_firestore.dart';

/// Mirrors `libs/auth/src/lib/classes/user-profile.ts`'s `UserRole`.
enum UserRole {
  ems,
  physician,
  nurse,
  admin,
  superAdmin;

  /// Firestore stores roles as the exact strings below (note `super-admin`,
  /// not `superAdmin`) — matches the Angular app's `UserRole` string union.
  static UserRole? fromFirestore(String value) {
    for (final role in UserRole.values) {
      if (role.wireValue == value) return role;
    }
    return null;
  }

  String get wireValue => switch (this) {
    UserRole.ems => 'ems',
    UserRole.physician => 'physician',
    UserRole.nurse => 'nurse',
    UserRole.admin => 'admin',
    UserRole.superAdmin => 'super-admin',
  };
}

/// Mirrors `libs/auth/src/lib/classes/user-profile.ts`'s `UserProfile`,
/// stored at Firestore `users/{uid}`. `role`/`organizationId` are
/// server-write-only (see firestore.rules) — never written from a client
/// here, same as the Angular app.
class UserProfile {
  const UserProfile({
    this.firstName,
    this.lastName,
    this.role = const [],
    this.workLocation,
    this.organizationId,
    this.newPatientAlertsExpiresAt,
    this.fcmTokens = const [],
  });

  factory UserProfile.fromFirestore(Map<String, Object?> data) {
    final rawRoles = data['role'];
    final rawFcmTokens = data['fcmTokens'];
    return UserProfile(
      firstName: data['firstName'] as String?,
      lastName: data['lastName'] as String?,
      role: rawRoles is List
          ? rawRoles
              .whereType<String>()
              .map(UserRole.fromFirestore)
              .whereType<UserRole>()
              .toList()
          : const [],
      workLocation: data['workLocation'] as String?,
      organizationId: data['organizationId'] as String?,
      newPatientAlertsExpiresAt:
          data['newPatientAlertsExpiresAt'] as Timestamp?,
      // `is List` check, not `as List?` — matches `role`'s handling above;
      // confirmed via a real test that the old unsafe cast throws instead
      // of defaulting to empty on a malformed value, unlike every other
      // field in this factory.
      fcmTokens: rawFcmTokens is List
          ? rawFcmTokens.whereType<String>().toList()
          : const [],
    );
  }

  final String? firstName;
  final String? lastName;
  final List<UserRole> role;
  final String? workLocation;
  final String? organizationId;
  final Timestamp? newPatientAlertsExpiresAt;
  final List<String> fcmTokens;

  bool hasRole(UserRole target) => role.contains(target);

  bool hasAnyRole(Iterable<UserRole> targets) =>
      targets.any((target) => role.contains(target));

  /// Mirrors `UserProfileService.initials` — empty unless both names are set.
  String get initials {
    if (firstName == null || firstName!.isEmpty || lastName == null || lastName!.isEmpty) {
      return '';
    }
    return '${firstName![0]}${lastName![0]}'.toUpperCase();
  }
}
