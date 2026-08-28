import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('vitalsHistoryProvider streams a patient\'s history newest-first', () async {
    final firestore = FakeFirebaseFirestore();
    final historyRef = firestore.collection('patients').doc('patient-1').collection('vitalsHistory');
    await historyRef.add({
      'heartRate': 80,
      'recordedAt': Timestamp.fromDate(DateTime(2026, 1, 1)),
    });
    await historyRef.add({
      'heartRate': 95,
      'recordedAt': Timestamp.fromDate(DateTime(2026, 1, 2)),
    });

    final container = ProviderContainer(
      overrides: [firestoreProvider.overrideWithValue(firestore)],
    );
    addTearDown(container.dispose);

    final history = await container.read(vitalsHistoryProvider('patient-1').future);

    expect(history, hasLength(2));
    // Newest (Jan 2) first.
    expect(history[0].vitals.heartRate, 95);
    expect(history[1].vitals.heartRate, 80);
  });

  test('vitalsHistoryProvider is empty for a patient with no history yet', () async {
    final firestore = FakeFirebaseFirestore();
    final container = ProviderContainer(
      overrides: [firestoreProvider.overrideWithValue(firestore)],
    );
    addTearDown(container.dispose);

    final history = await container.read(vitalsHistoryProvider('no-history-patient').future);
    expect(history, isEmpty);
  });

  test('vitalsHistoryProvider is a .family — different patientIds get independent streams', () async {
    final firestore = FakeFirebaseFirestore();
    await firestore
        .collection('patients')
        .doc('patient-a')
        .collection('vitalsHistory')
        .add({'heartRate': 70, 'recordedAt': Timestamp.fromDate(DateTime(2026, 1, 1))});
    await firestore
        .collection('patients')
        .doc('patient-b')
        .collection('vitalsHistory')
        .add({'heartRate': 110, 'recordedAt': Timestamp.fromDate(DateTime(2026, 1, 1))});

    final container = ProviderContainer(
      overrides: [firestoreProvider.overrideWithValue(firestore)],
    );
    addTearDown(container.dispose);

    final historyA = await container.read(vitalsHistoryProvider('patient-a').future);
    final historyB = await container.read(vitalsHistoryProvider('patient-b').future);

    expect(historyA.single.vitals.heartRate, 70);
    expect(historyB.single.vitals.heartRate, 110);
  });
}
