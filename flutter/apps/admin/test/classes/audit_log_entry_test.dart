import 'package:admin/classes/audit_log_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AuditLogEntry.fromJson', () {
    test('parses a fully-populated entry', () {
      final entry = AuditLogEntry.fromJson({
        'id': 'log-1',
        'action': 'user.create',
        'actorEmail': 'admin@example.com',
        'target': 'user-1',
        'details': {'role': 'physician'},
        'timestampMs': 1700000000000,
      });

      expect(entry.id, 'log-1');
      expect(entry.action, 'user.create');
      expect(entry.actorEmail, 'admin@example.com');
      expect(entry.target, 'user-1');
      expect(entry.details, {'role': 'physician'});
      expect(entry.timestamp, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    });

    test('non-string detail keys are coerced to strings', () {
      final entry = AuditLogEntry.fromJson({
        'details': {1: 'one', true: 'yes'},
      });

      expect(entry.details, {'1': 'one', 'true': 'yes'});
    });

    test('a non-Map details value defaults to an empty map', () {
      final entry = AuditLogEntry.fromJson({'details': 'not a map'});
      expect(entry.details, isEmpty);
    });

    test('missing string fields default to empty strings, target/timestamp to null', () {
      final entry = AuditLogEntry.fromJson(const {});

      expect(entry.id, '');
      expect(entry.action, '');
      expect(entry.actorEmail, '');
      expect(entry.target, isNull);
      expect(entry.details, isEmpty);
      expect(entry.timestamp, isNull);
    });
  });

  group('AuditLogPage.fromJson', () {
    test('parses entries and hasMore', () {
      final page = AuditLogPage.fromJson({
        'entries': [
          {'id': 'log-1', 'action': 'user.create'},
          {'id': 'log-2', 'action': 'user.delete'},
        ],
        'hasMore': true,
      });

      expect(page.entries, hasLength(2));
      expect(page.entries[0].id, 'log-1');
      expect(page.entries[1].id, 'log-2');
      expect(page.hasMore, true);
    });

    test('non-Map entries in the list are skipped', () {
      final page = AuditLogPage.fromJson({
        'entries': [
          {'id': 'log-1'},
          'not a map',
          42,
        ],
      });

      expect(page.entries, hasLength(1));
      expect(page.entries.single.id, 'log-1');
    });

    test('a missing/non-List entries value defaults to an empty list, hasMore to false', () {
      final page = AuditLogPage.fromJson(const {});

      expect(page.entries, isEmpty);
      expect(page.hasMore, false);
    });
  });

  group('auditActionLabels', () {
    test('has a label for every action this test suite (and the real backend) can produce', () {
      expect(auditActionLabels['user.create'], 'Created user');
      expect(auditActionLabels['patient.decrypt'], 'Viewed decrypted patient info');
      expect(auditActionLabels, isNotEmpty);
    });
  });
}
