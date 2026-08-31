import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AccountStatus.fromJson', () {
    test('parses a fully-populated response', () {
      final status = AccountStatus.fromJson({
        'exists': true,
        'hasPassword': true,
        'roleAllowed': true,
        'role': ['ems'],
      });

      expect(status.exists, true);
      expect(status.hasPassword, true);
      expect(status.roleAllowed, true);
      expect(status.role, [UserRole.ems]);
    });

    test('defaults exists/hasPassword to false, roleAllowed to true, role to [] when the response is empty', () {
      final status = AccountStatus.fromJson(const {});

      expect(status.exists, false);
      expect(status.hasPassword, false);
      // Missing, not false — see the model's own doc comment: a response
      // somehow missing this field should never lock every caller out on
      // its own.
      expect(status.roleAllowed, true);
      expect(status.role, isEmpty);
    });

    test('an account that exists but has no password yet (the setInitialPassword flow)', () {
      final status = AccountStatus.fromJson({'exists': true, 'hasPassword': false});

      expect(status.exists, true);
      expect(status.hasPassword, false);
    });

    test('an account whose role does not match the calling app (roleAllowed: false)', () {
      final status = AccountStatus.fromJson({
        'exists': true,
        'hasPassword': true,
        'roleAllowed': false,
        'role': ['physician'],
      });

      expect(status.roleAllowed, false);
      expect(status.role, [UserRole.physician]);
    });

    test('an unrecognized role string is silently dropped, not thrown', () {
      final status = AccountStatus.fromJson({
        'role': ['ems', 'not-a-real-role'],
      });

      expect(status.role, [UserRole.ems]);
    });
  });
}
