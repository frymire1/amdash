import 'package:cloud_firestore/cloud_firestore.dart';

import 'patient.dart';

/// One past vitals reading for a patient, from
/// `patients/{patientId}/vitalsHistory` — appended server-side
/// (functions/src/patients.ts's onPatientCreated/onPatientUpdated)
/// whenever EMS submits a patient with different vitals than last time,
/// never written by a client directly. [VitalsHistoryService] orders these
/// newest-first, so index 0 is always the most recently recorded set.
/// Shared by physician (read-only vitals display) and EMS (edit-form trend
/// icons) — lives in amdash_core rather than either app's private lib.
class VitalsHistoryEntry {
  const VitalsHistoryEntry({required this.vitals, required this.recordedAt});

  factory VitalsHistoryEntry.fromFirestore(Map<String, Object?> data) {
    return VitalsHistoryEntry(
      // Reuses PatientVitals.fromFirestore directly — a history entry's
      // vitals fields are flattened at the document's top level (alongside
      // recordedAt/recordedBy) specifically so this doesn't need its own
      // parsing logic that could drift from the patient doc's own.
      vitals: PatientVitals.fromFirestore(data),
      recordedAt: (data['recordedAt'] as Timestamp?)?.toDate(),
    );
  }

  final PatientVitals vitals;

  /// Null only in the brief window between this entry being written and
  /// its `serverTimestamp()` resolving — practically never observed by a
  /// client, since nothing reads an entry until well after that.
  final DateTime? recordedAt;
}
