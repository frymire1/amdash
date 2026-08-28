import 'package:amdash_core/amdash_core.dart';
import 'package:ems/classes/uploaded_patient.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UploadedPatient', () {
    test('holds exactly what it was constructed with', () {
      final patient = Patient.fromFirestore('patient-1', const {});
      final uploaded = UploadedPatient(id: 'patient-1', patient: patient);

      expect(uploaded.id, 'patient-1');
      expect(uploaded.patient, same(patient));
    });
  });
}
