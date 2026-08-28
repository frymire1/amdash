import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VitalsHistoryEntry.fromFirestore', () {
    test('parses recordedAt and reuses PatientVitals.fromFirestore for the flattened vitals fields', () {
      final recordedAt = DateTime(2026, 8, 12, 14, 30);
      final entry = VitalsHistoryEntry.fromFirestore({
        'recordedAt': Timestamp.fromDate(recordedAt),
        'heartRate': 95,
        'bloodPressure': '120/80',
        'oxygen': 98,
        'temperature': 37.1,
        'respiratoryRate': 16,
        'gcs': 15,
      });

      expect(entry.recordedAt, recordedAt);
      expect(entry.vitals.heartRate, 95);
      expect(entry.vitals.bloodPressure, '120/80');
      expect(entry.vitals.oxygen, 98);
      expect(entry.vitals.temperature, 37.1);
      expect(entry.vitals.respiratoryRate, 16);
      expect(entry.vitals.gcs, 15);
    });

    test('recordedAt is null in the brief window before its serverTimestamp() resolves', () {
      final entry = VitalsHistoryEntry.fromFirestore(const {'heartRate': 88});

      expect(entry.recordedAt, isNull);
      expect(entry.vitals.heartRate, 88);
    });
  });
}
