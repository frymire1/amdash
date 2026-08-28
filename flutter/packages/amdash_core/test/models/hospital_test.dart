import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Hospital.fromFirestore', () {
    test('parses a fully-populated document', () {
      final hospital = Hospital.fromFirestore('hosp-1', {
        'name': "St. Michael's Hospital",
        'address': '30 Bond St',
        'latitude': 43.6532,
        'longitude': -79.3832,
        'organizationId': 'org-1',
      });

      expect(hospital.id, 'hosp-1');
      expect(hospital.name, "St. Michael's Hospital");
      expect(hospital.address, '30 Bond St');
      expect(hospital.latitude, 43.6532);
      expect(hospital.longitude, -79.3832);
      expect(hospital.organizationId, 'org-1');
    });

    test('defaults every field when the document is empty', () {
      final hospital = Hospital.fromFirestore('hosp-2', const {});

      expect(hospital.name, '');
      expect(hospital.address, '');
      expect(hospital.latitude, 0);
      expect(hospital.longitude, 0);
      expect(hospital.organizationId, '');
    });

    test('coerces integer lat/lng (Firestore can send either) to double', () {
      final hospital = Hospital.fromFirestore('hosp-3', const {
        'latitude': 43,
        'longitude': -79,
      });

      expect(hospital.latitude, 43.0);
      expect(hospital.longitude, -79.0);
      expect(hospital.latitude, isA<double>());
      expect(hospital.longitude, isA<double>());
    });
  });
}
