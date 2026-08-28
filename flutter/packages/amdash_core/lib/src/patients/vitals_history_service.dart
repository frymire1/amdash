import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../firebase/firebase_providers.dart';
import '../models/vitals_history_entry.dart';

/// A live listener on `patients/{patientId}/vitalsHistory`, newest first.
/// Was originally a one-time fetch on the theory that both apps' own
/// vitals-display widgets "already re-fetch whenever rebuilt for a given
/// patient" — false in practice: physician's PatientViewer keeps the same
/// widget (and this same `family` instance, since `family` caches per
/// patientId and nothing tears it down while the same patient stays
/// selected) mounted for as long as a physician keeps one patient open, so
/// a `FutureProvider` here only ever fetched once per viewing session —
/// confirmed for real via a genuine report that a physician had to reload
/// the whole app to see a vitals update EMS had already submitted. `family`
/// still naturally caches per patientId; `autoDispose` still drops that
/// listener once nothing's watching it anymore rather than holding every
/// viewed patient's history open for the rest of the session.
final vitalsHistoryProvider = StreamProvider.autoDispose
    .family<List<VitalsHistoryEntry>, String>((ref, patientId) {
      return ref
          .watch(firestoreProvider)
          .collection('patients')
          .doc(patientId)
          .collection('vitalsHistory')
          .orderBy('recordedAt', descending: true)
          .snapshots()
          .map(
            (snapshot) => [
              for (final doc in snapshot.docs)
                VitalsHistoryEntry.fromFirestore(doc.data()),
            ],
          );
    });
