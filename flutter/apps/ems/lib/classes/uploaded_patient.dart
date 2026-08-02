import 'package:amdash_core/amdash_core.dart';

/// Mirrors `apps/ems/src/app/classes/uploaded-patient.ts`.
class UploadedPatient {
  const UploadedPatient({required this.id, required this.patient});

  final String id;
  final Patient patient;
}
