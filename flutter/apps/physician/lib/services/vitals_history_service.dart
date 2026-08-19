import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/vitals_history_entry.dart';

/// A one-time fetch of `patients/{patientId}/vitalsHistory`, newest first —
/// not a live listener, since new entries only ever appear when EMS
/// submits a change (infrequent, and `PatientViewer` already re-fetches
/// whenever it's rebuilt for a given patient — see its own key). `family`
/// naturally caches per patientId; `autoDispose` drops that cache once
/// nothing's watching it anymore (e.g. the physician moves on to a
/// different patient) rather than holding every viewed patient's history
/// in memory for the rest of the session.
final vitalsHistoryProvider = FutureProvider.autoDispose.family<List<VitalsHistoryEntry>, String>((ref, patientId) async {
  final snapshot = await FirebaseFirestore.instance
      .collection('patients')
      .doc(patientId)
      .collection('vitalsHistory')
      .orderBy('recordedAt', descending: true)
      .get();
  return [for (final doc in snapshot.docs) VitalsHistoryEntry.fromFirestore(doc.data())];
});
