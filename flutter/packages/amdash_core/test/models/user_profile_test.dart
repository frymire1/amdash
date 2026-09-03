import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UserRole.fromFirestore', () {
    test('maps every wire value to its role, including the super-admin/superAdmin name mismatch', () {
      expect(UserRole.fromFirestore('ems'), UserRole.ems);
      expect(UserRole.fromFirestore('physician'), UserRole.physician);
      expect(UserRole.fromFirestore('nurse'), UserRole.nurse);
      expect(UserRole.fromFirestore('admin'), UserRole.admin);
      // Firestore stores this hyphenated, unlike the Dart enum member name.
      expect(UserRole.fromFirestore('super-admin'), UserRole.superAdmin);
    });

    test('an unrecognized string (including the Dart member name "superAdmin") returns null', () {
      expect(UserRole.fromFirestore('superAdmin'), isNull);
      expect(UserRole.fromFirestore('not-a-role'), isNull);
      expect(UserRole.fromFirestore(''), isNull);
    });
  });

  group('UserRole.wireValue', () {
    test('round-trips every role through its wire string', () {
      for (final role in UserRole.values) {
        expect(UserRole.fromFirestore(role.wireValue), role);
      }
    });
  });

  group('UserProfile.fromFirestore', () {
    test('parses a fully-populated document', () {
      final expiresAt = Timestamp.fromDate(DateTime(2026, 12, 31));
      final profile = UserProfile.fromFirestore({
        'firstName': 'Jordan',
        'lastName': 'Smith',
        'role': ['physician', 'nurse'],
        'workLocation': "St. Michael's Hospital",
        'organizationId': 'org-1',
        'newPatientAlertsExpiresAt': expiresAt,
        'fcmTokens': ['token-1', 'token-2'],
        'etaAlertThresholdsMinutes': [60, 15],
      });

      expect(profile.firstName, 'Jordan');
      expect(profile.lastName, 'Smith');
      expect(profile.role, [UserRole.physician, UserRole.nurse]);
      expect(profile.workLocation, "St. Michael's Hospital");
      expect(profile.organizationId, 'org-1');
      expect(profile.newPatientAlertsExpiresAt, expiresAt);
      expect(profile.fcmTokens, ['token-1', 'token-2']);
      expect(profile.etaAlertThresholdsMinutes, [60, 15]);
    });

    test('defaults role/fcmTokens/etaAlertThresholdsMinutes to empty lists and leaves everything else null when the document is empty', () {
      final profile = UserProfile.fromFirestore(const {});

      expect(profile.firstName, isNull);
      expect(profile.lastName, isNull);
      expect(profile.role, isEmpty);
      expect(profile.workLocation, isNull);
      expect(profile.organizationId, isNull);
      expect(profile.newPatientAlertsExpiresAt, isNull);
      expect(profile.fcmTokens, isEmpty);
      expect(profile.etaAlertThresholdsMinutes, isEmpty);
    });

    test('role defaults to empty when the field is present but not a List', () {
      final profile = UserProfile.fromFirestore(const {'role': 'physician'});
      expect(profile.role, isEmpty);
    });

    test('filters out unrecognized role strings rather than throwing', () {
      final profile = UserProfile.fromFirestore(const {
        'role': ['physician', 'not-a-real-role', 'ems'],
      });
      expect(profile.role, [UserRole.physician, UserRole.ems]);
    });

    test('fcmTokens defaults to empty when the field is present but not a List', () {
      final profile = UserProfile.fromFirestore(const {'fcmTokens': 'not-a-list'});
      expect(profile.fcmTokens, isEmpty);
    });

    test('etaAlertThresholdsMinutes defaults to empty when the field is present but not a List', () {
      final profile = UserProfile.fromFirestore(const {'etaAlertThresholdsMinutes': 'not-a-list'});
      expect(profile.etaAlertThresholdsMinutes, isEmpty);
    });
  });

  group('UserProfile.hasRole / hasAnyRole', () {
    test('hasRole is true only for a role actually present', () {
      const profile = UserProfile(role: [UserRole.ems]);
      expect(profile.hasRole(UserRole.ems), true);
      expect(profile.hasRole(UserRole.physician), false);
    });

    test('hasAnyRole is true if any target role is present', () {
      const profile = UserProfile(role: [UserRole.physician]);
      expect(profile.hasAnyRole([UserRole.physician, UserRole.nurse]), true);
      expect(profile.hasAnyRole([UserRole.ems, UserRole.admin]), false);
    });
  });

  group('UserProfile.initials', () {
    test('both first and last name set', () {
      const profile = UserProfile(firstName: 'Jordan', lastName: 'Smith');
      expect(profile.initials, 'JS');
    });

    test('empty when firstName is missing', () {
      const profile = UserProfile(lastName: 'Smith');
      expect(profile.initials, '');
    });

    test('empty when lastName is missing', () {
      const profile = UserProfile(firstName: 'Jordan');
      expect(profile.initials, '');
    });

    test('empty when firstName is an empty string', () {
      const profile = UserProfile(firstName: '', lastName: 'Smith');
      expect(profile.initials, '');
    });

    test('empty when lastName is an empty string', () {
      const profile = UserProfile(firstName: 'Jordan', lastName: '');
      expect(profile.initials, '');
    });
  });
}
