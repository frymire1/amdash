import 'package:admin/classes/managed_user.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ManagedUser.fromJson', () {
    test('parses a fully-populated user', () {
      final user = ManagedUser.fromJson({
        'uid': 'user-1',
        'email': 'user1@example.com',
        'firstName': 'Jordan',
        'lastName': 'Smith',
        'role': ['physician', 'nurse'],
        'disabled': true,
        'hasPassword': false,
        'mfaEnrolled': true,
      });

      expect(user.uid, 'user-1');
      expect(user.email, 'user1@example.com');
      expect(user.firstName, 'Jordan');
      expect(user.lastName, 'Smith');
      expect(user.role, [UserRole.physician, UserRole.nurse]);
      expect(user.disabled, true);
      expect(user.hasPassword, false);
      expect(user.mfaEnrolled, true);
    });

    test('an unrecognized role string is dropped rather than crashing', () {
      final user = ManagedUser.fromJson({
        'role': ['physician', 'not-a-real-role'],
      });

      expect(user.role, [UserRole.physician]);
    });

    test('a non-List role value defaults to an empty list', () {
      final user = ManagedUser.fromJson({'role': 'physician'});
      expect(user.role, isEmpty);
    });

    test('missing fields default to empty strings/list, disabled to false, hasPassword/mfaEnrolled '
        'to their documented non-obvious defaults', () {
      final user = ManagedUser.fromJson(const {});

      expect(user.uid, '');
      expect(user.email, '');
      expect(user.firstName, '');
      expect(user.lastName, '');
      expect(user.role, isEmpty);
      // Absent from updateUser's response — defaults to "active"/"has a
      // password", not "suspended"/"passwordless", per the field's own
      // doc comment.
      expect(user.disabled, false);
      expect(user.hasPassword, true);
      expect(user.mfaEnrolled, false);
    });
  });

  group('assignableRoles', () {
    test('is exactly the 3 roles an admin can assign — never admin or super-admin', () {
      expect(assignableRoles, [UserRole.ems, UserRole.physician, UserRole.nurse]);
      expect(assignableRoles, isNot(contains(UserRole.admin)));
      expect(assignableRoles, isNot(contains(UserRole.superAdmin)));
    });
  });
}
