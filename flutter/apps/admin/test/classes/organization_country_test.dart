import 'package:admin/classes/organization_country.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('organizationCountries', () {
    test('includes CA with the exact code setOrganizationCountry expects', () {
      expect(organizationCountries['CA'], 'Canada');
    });

    test('has a catch-all OTHER entry', () {
      expect(organizationCountries['OTHER'], 'Other');
    });

    test('every key is a plain human label, not empty', () {
      for (final entry in organizationCountries.entries) {
        expect(entry.value, isNotEmpty);
      }
    });
  });
}
