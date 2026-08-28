import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AccountStatus.fromJson', () {
    test('parses a fully-populated response', () {
      final status = AccountStatus.fromJson({'exists': true, 'hasPassword': true});

      expect(status.exists, true);
      expect(status.hasPassword, true);
    });

    test('defaults both flags to false when the response is empty', () {
      final status = AccountStatus.fromJson(const {});

      expect(status.exists, false);
      expect(status.hasPassword, false);
    });

    test('an account that exists but has no password yet (the setInitialPassword flow)', () {
      final status = AccountStatus.fromJson({'exists': true, 'hasPassword': false});

      expect(status.exists, true);
      expect(status.hasPassword, false);
    });
  });
}
