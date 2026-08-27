import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PatientVitals.fromFirestore', () {
    test('parses a fully-populated document', () {
      final vitals = PatientVitals.fromFirestore({
        'heartRate': 95,
        'bloodPressure': '120/80',
        'oxygen': 98,
        'temperature': 37.1,
        'respiratoryRate': 16,
        'gcs': 15,
      });

      expect(vitals.heartRate, 95);
      expect(vitals.bloodPressure, '120/80');
      expect(vitals.oxygen, 98);
      expect(vitals.temperature, 37.1);
      expect(vitals.respiratoryRate, 16);
      expect(vitals.gcs, 15);
    });

    test('preserves the EMS blank-field sentinel string rather than coercing it', () {
      // heartRate/oxygen/temperature are `Object?` specifically to carry
      // this — see the class's own doc comment.
      final vitals = PatientVitals.fromFirestore({
        'heartRate': 'Unknown',
        'bloodPressure': 'Unknown',
        'oxygen': 'Unknown',
        'temperature': 'Unknown',
      });

      expect(vitals.heartRate, 'Unknown');
      expect(vitals.oxygen, 'Unknown');
      expect(vitals.temperature, 'Unknown');
      expect(vitals.bloodPressure, 'Unknown');
    });

    test('defaults a missing bloodPressure to an empty string, and respiratoryRate/gcs to null', () {
      final vitals = PatientVitals.fromFirestore(const {});

      expect(vitals.bloodPressure, '');
      expect(vitals.respiratoryRate, isNull);
      expect(vitals.gcs, isNull);
    });

    test('coerces respiratoryRate/gcs from num to int (Firestore integers can arrive as double)', () {
      final vitals = PatientVitals.fromFirestore(const {'respiratoryRate': 18.0, 'gcs': 14.0});

      expect(vitals.respiratoryRate, 18);
      expect(vitals.gcs, 14);
    });
  });

  group('PatientField.fromFirestore', () {
    test('a plain string is treated as already-resolved plaintext', () {
      final field = PatientField.fromFirestore('Jordan Smith');

      expect(field.isEncrypted, false);
      expect(field.plaintext, 'Jordan Smith');
      expect(field.fingerprint, isNull);
      expect(field.isResolved, true);
    });

    test('an encrypted-blob map is not resolved yet, and carries its ciphertext as a fingerprint', () {
      final field = PatientField.fromFirestore({'__enc': 1, 'ciphertext': 'abc123'});

      expect(field.isEncrypted, true);
      expect(field.plaintext, isNull);
      expect(field.fingerprint, 'abc123');
      expect(field.isResolved, false);
    });

    test('an encrypted-blob map with a non-string ciphertext has no usable fingerprint', () {
      final field = PatientField.fromFirestore({'__enc': 1, 'ciphertext': 12345});
      expect(field.fingerprint, isNull);
    });

    test('null/missing falls back to an empty, non-encrypted plaintext rather than throwing', () {
      final field = PatientField.fromFirestore(null);
      expect(field.isEncrypted, false);
      expect(field.plaintext, '');
    });

    test('PatientField.resolved wraps an already-known plaintext value directly', () {
      final field = PatientField.resolved('Decrypted Name');
      expect(field.isEncrypted, false);
      expect(field.plaintext, 'Decrypted Name');
      expect(field.fingerprint, isNull);
    });
  });

  group('PatientFieldDisplay extension', () {
    test('display() shows "Decrypting…" while an encrypted field has no resolved plaintext yet', () {
      final field = PatientField.fromFirestore({'__enc': 1, 'ciphertext': 'abc'});
      expect(field.display(), 'Decrypting…');
      expect(field.isProvided, false);
    });

    test('display() shows the resolved plaintext once known', () {
      final field = PatientField.resolved('Jordan Smith');
      expect(field.display(), 'Jordan Smith');
      expect(field.isProvided, true);
    });

    test('display() falls back to notAddedText for the blank-field sentinel, with a caller-supplied message', () {
      final field = PatientField.resolved('Unknown');
      expect(field.display(), 'Not added yet');
      expect(field.display(notAddedText: 'Not added by EMS yet'), 'Not added by EMS yet');
      expect(field.isProvided, false);
    });
  });

  group('Patient.fromFirestore', () {
    test('parses a fully-populated document with plaintext name/healthcareNumber', () {
      final patient = Patient.fromFirestore('patient-1', {
        'name': 'Jordan Smith',
        'gender': 'Male',
        'age': 42,
        'healthcareNumber': '1234567890',
        'vitals': {'heartRate': 95, 'bloodPressure': '120/80', 'oxygen': 98, 'temperature': 37.0},
        'notes': 'Alert and oriented.',
        'destination': "St. Michael's Hospital",
        'ivSize': '18G',
        'ivPlacement': 'Left Antecubital (AC)',
        'treatment': 'IV fluids',
        'status': 'active',
      });

      expect(patient.id, 'patient-1');
      expect(patient.name.plaintext, 'Jordan Smith');
      expect(patient.gender, 'Male');
      expect(patient.age, 42);
      expect(patient.healthcareNumber.plaintext, '1234567890');
      expect(patient.vitals.heartRate, 95);
      expect(patient.notes, 'Alert and oriented.');
      expect(patient.destination, "St. Michael's Hospital");
      expect(patient.ivSize, '18G');
      expect(patient.ivPlacement, 'Left Antecubital (AC)');
      expect(patient.treatment, 'IV fluids');
      expect(patient.status, 'active');
    });

    test('parses an encrypted name/healthcareNumber as unresolved fields', () {
      final patient = Patient.fromFirestore('patient-2', {
        'name': {'__enc': 1, 'ciphertext': 'name-cipher'},
        'healthcareNumber': {'__enc': 1, 'ciphertext': 'hn-cipher'},
        'gender': 'Female',
        'age': 30,
        'vitals': <String, Object?>{},
      });

      expect(patient.name.isEncrypted, true);
      expect(patient.name.fingerprint, 'name-cipher');
      expect(patient.healthcareNumber.isEncrypted, true);
      expect(patient.healthcareNumber.fingerprint, 'hn-cipher');
    });

    test('defaults gender to an empty string and leaves optional fields null when entirely absent', () {
      final patient = Patient.fromFirestore('patient-3', const {});

      expect(patient.gender, '');
      expect(patient.age, isNull);
      expect(patient.notes, isNull);
      expect(patient.destination, isNull);
      expect(patient.ivSize, isNull);
      expect(patient.ivPlacement, isNull);
      expect(patient.treatment, isNull);
      expect(patient.status, isNull);
      // vitals is always present (a non-nullable field) even with no
      // 'vitals' map in the source document at all.
      expect(patient.vitals.bloodPressure, '');
    });

    test('withDecryptedFields splices in resolved plaintext without touching anything else', () {
      final original = Patient.fromFirestore('patient-4', {
        'name': {'__enc': 1, 'ciphertext': 'name-cipher'},
        'healthcareNumber': {'__enc': 1, 'ciphertext': 'hn-cipher'},
        'gender': 'Male',
        'age': 50,
        'destination': 'General Hospital',
        'vitals': const {'heartRate': 80},
      });

      final resolved = original.withDecryptedFields(name: 'Jordan Smith', healthcareNumber: '1234567890');

      expect(resolved.id, 'patient-4');
      expect(resolved.name.plaintext, 'Jordan Smith');
      expect(resolved.healthcareNumber.plaintext, '1234567890');
      // Untouched fields carry over exactly.
      expect(resolved.gender, 'Male');
      expect(resolved.age, 50);
      expect(resolved.destination, 'General Hospital');
      expect(resolved.vitals.heartRate, 80);
    });

    test('withDecryptedFields leaves a field alone when its resolved value is omitted', () {
      final original = Patient.fromFirestore('patient-5', {
        'name': {'__enc': 1, 'ciphertext': 'name-cipher'},
        'healthcareNumber': {'__enc': 1, 'ciphertext': 'hn-cipher'},
        'gender': 'Other',
        'vitals': <String, Object?>{},
      });

      final resolved = original.withDecryptedFields(name: 'Only Name Resolved');

      expect(resolved.name.plaintext, 'Only Name Resolved');
      // healthcareNumber wasn't passed, so it's still the original,
      // unresolved encrypted field.
      expect(resolved.healthcareNumber.isEncrypted, true);
      expect(resolved.healthcareNumber.plaintext, isNull);
    });
  });

  group('isProvidedValue', () {
    test('a number counts as provided even when it is zero', () {
      expect(isProvidedValue(0), true);
      expect(isProvidedValue(98.6), true);
    });

    test('a non-empty string that is not the "Unknown" sentinel counts as provided', () {
      expect(isProvidedValue('120/80'), true);
    });

    test('an empty string, the literal "Unknown" sentinel, and null do not count as provided', () {
      expect(isProvidedValue(''), false);
      expect(isProvidedValue('Unknown'), false);
      expect(isProvidedValue(null), false);
    });

    test('a non-num/non-String value (e.g. a bool or a Map) is never provided', () {
      expect(isProvidedValue(true), false);
      expect(isProvidedValue(<String, Object?>{}), false);
    });
  });

  group('numOrNull', () {
    test('passes a num value through unchanged', () {
      expect(numOrNull(95), 95);
      expect(numOrNull(37.5), 37.5);
    });

    test('returns null for the "Unknown" sentinel and any other non-num value', () {
      expect(numOrNull('Unknown'), isNull);
      expect(numOrNull(null), isNull);
      expect(numOrNull('120/80'), isNull);
    });
  });

  group('bloodPressurePart', () {
    test('splits a well-formed "systolic/diastolic" reading', () {
      expect(bloodPressurePart('120/80', 0), 120);
      expect(bloodPressurePart('120/80', 1), 80);
    });

    test('tolerates surrounding whitespace around each half', () {
      expect(bloodPressurePart('120 / 80', 0), 120);
      expect(bloodPressurePart('120 / 80', 1), 80);
    });

    test('returns null for the blank-field sentinel (no "/" to split on)', () {
      expect(bloodPressurePart('Unknown', 0), isNull);
      expect(bloodPressurePart('Unknown', 1), isNull);
    });

    test('returns null for an empty string or a malformed (non-two-part) reading', () {
      expect(bloodPressurePart('', 0), isNull);
      expect(bloodPressurePart('120', 0), isNull);
      expect(bloodPressurePart('120/80/60', 0), isNull);
    });
  });
}
