import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Organization.fromFirestore', () {
    test('parses a fully-populated document', () {
      final org = Organization.fromFirestore('org-1', {
        'name': 'Toronto EMS',
        'retainAllData': true,
        'country': 'Canada',
        'cmekRequested': true,
        'auditLoggingEnabled': false,
        'fhirExportEnabled': true,
      });

      expect(org.id, 'org-1');
      expect(org.name, 'Toronto EMS');
      expect(org.retainAllData, true);
      expect(org.country, 'Canada');
      expect(org.cmekRequested, true);
      expect(org.auditLoggingEnabled, false);
      expect(org.fhirExportEnabled, true);
    });

    test('defaults name to an empty string and leaves every toggle null when the document is empty', () {
      final org = Organization.fromFirestore('org-2', const {});

      expect(org.name, '');
      // Every toggle stays null (not a guessed default) — an org created
      // before a field existed shouldn't have that field silently
      // defaulted, per the model's own doc comments on country/
      // auditLoggingEnabled/fhirExportEnabled.
      expect(org.retainAllData, isNull);
      expect(org.country, isNull);
      expect(org.cmekRequested, isNull);
      expect(org.auditLoggingEnabled, isNull);
      expect(org.fhirExportEnabled, isNull);
    });
  });
}
