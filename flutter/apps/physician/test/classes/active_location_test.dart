import 'package:flutter_test/flutter_test.dart';
import 'package:physician/classes/active_location.dart';

void main() {
  group('ActiveLocation', () {
    test('holds exactly what it was constructed with, including the optional previous-fix fields', () {
      const location = ActiveLocation(
        patientId: 'patient-1',
        updatedAtMs: 1000,
        latitude: 45.4,
        longitude: -75.7,
        previousLatitude: 45.3,
        previousLongitude: -75.6,
        previousUpdatedAtMs: 500,
      );

      expect(location.patientId, 'patient-1');
      expect(location.updatedAtMs, 1000);
      expect(location.latitude, 45.4);
      expect(location.longitude, -75.7);
      expect(location.previousLatitude, 45.3);
      expect(location.previousLongitude, -75.6);
      expect(location.previousUpdatedAtMs, 500);
    });

    test('the optional previous-fix/coordinate fields default to null', () {
      const location = ActiveLocation(patientId: 'patient-1', updatedAtMs: 1000);

      expect(location.latitude, isNull);
      expect(location.longitude, isNull);
      expect(location.previousLatitude, isNull);
      expect(location.previousLongitude, isNull);
      expect(location.previousUpdatedAtMs, isNull);
    });
  });
}
