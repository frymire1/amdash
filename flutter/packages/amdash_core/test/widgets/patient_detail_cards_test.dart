import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

const _emptyVitals = PatientVitals(heartRate: null, bloodPressure: '', oxygen: null, temperature: null);

Patient _patient({String? id = 'patient-1'}) {
  return Patient(id: id, name: PatientField.resolved('Jordan Smith'), healthcareNumber: PatientField.resolved('123'), gender: '', age: null, vitals: _emptyVitals);
}

void main() {
  group('numOrNull / bloodPressurePart', () {
    test('numOrNull passes through a num, filters out the Unknown sentinel', () {
      expect(numOrNull(42), 42);
      expect(numOrNull('Unknown'), isNull);
      expect(numOrNull(null), isNull);
    });

    test('bloodPressurePart splits a valid "120/80" reading', () {
      expect(bloodPressurePart('120/80', 0), 120);
      expect(bloodPressurePart('120/80', 1), 80);
    });

    test('bloodPressurePart returns null for a missing or Unknown reading', () {
      expect(bloodPressurePart('', 0), isNull);
      expect(bloodPressurePart('Unknown', 0), isNull);
    });
  });

  group('PatientInfoCard', () {
    testWidgets('renders a title and its rows', (tester) async {
      await pumpApp(
        tester,
        const PatientInfoCard(title: 'Destination', rows: [Text('General Hospital')]),
      );

      expect(find.text('Destination'), findsOneWidget);
      expect(find.text('General Hospital'), findsOneWidget);
    });
  });

  group('PatientInfoChip', () {
    testWidgets('a provided value renders normally, no trend icon without series', (tester) async {
      await pumpApp(tester, const PatientInfoChip('Heart Rate', 95, suffix: 'bpm'));

      expect(find.text('95 bpm'), findsOneWidget);
      expect(find.byIcon(Icons.show_chart), findsNothing);
    });

    testWidgets('an unprovided value falls back to "Not added by EMS yet", italicized', (tester) async {
      await pumpApp(tester, const PatientInfoChip('Heart Rate', 'Unknown'));

      final text = tester.widget<Text>(find.text('Not added by EMS yet'));
      expect(text.style!.fontStyle, FontStyle.italic);
    });

    testWidgets('the trend icon only appears once history has more than one entry', (tester) async {
      final oneEntry = [VitalsHistoryEntry(vitals: _emptyVitals, recordedAt: DateTime(2024))];
      final twoEntries = [
        VitalsHistoryEntry(vitals: _emptyVitals, recordedAt: DateTime(2024)),
        VitalsHistoryEntry(vitals: _emptyVitals, recordedAt: DateTime(2024, 1, 2)),
      ];
      final series = [VitalSeries(label: 'Heart Rate', selector: (v) => numOrNull(v.heartRate))];

      await pumpApp(
        tester,
        PatientInfoChip('Heart Rate', 95, history: oneEntry, trendSeries: series),
      );
      expect(find.byKey(const Key('vitals_trend_Heart Rate')), findsNothing);

      await pumpApp(
        tester,
        PatientInfoChip('Heart Rate', 95, history: twoEntries, trendSeries: series),
      );
      expect(find.byKey(const Key('vitals_trend_Heart Rate')), findsOneWidget);
    });

    testWidgets('tapping the trend icon opens the trend dialog', (tester) async {
      final history = [
        VitalsHistoryEntry(vitals: _emptyVitals, recordedAt: DateTime(2024)),
        VitalsHistoryEntry(vitals: _emptyVitals, recordedAt: DateTime(2024, 1, 2)),
      ];
      final series = [VitalSeries(label: 'Heart Rate', selector: (v) => numOrNull(v.heartRate))];

      await pumpApp(
        tester,
        PatientInfoChip('Heart Rate', 95, suffix: 'bpm', history: history, trendSeries: series),
      );

      await tester.tap(find.byKey(const Key('vitals_trend_Heart Rate')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
    });
  });

  group('PatientTreatmentCard', () {
    testWidgets('a provided treatment renders normally with IV chips', (tester) async {
      final patient = _patient().copyWithTestFields(treatment: 'IV fluids', ivSize: '18G', ivPlacement: 'Left AC');
      await pumpApp(tester, PatientTreatmentCard(patient: patient));

      expect(find.text('IV fluids'), findsOneWidget);
      expect(find.text('18G'), findsOneWidget);
    });

    testWidgets('an unprovided treatment falls back to "Not added by EMS yet"', (tester) async {
      await pumpApp(tester, PatientTreatmentCard(patient: _patient()));

      expect(find.text('Not added by EMS yet'), findsWidgets);
    });
  });

  group('PatientTextCard', () {
    testWidgets('a provided value renders as-is', (tester) async {
      await pumpApp(tester, const PatientTextCard(title: 'Notes', text: 'Patient is stable'));

      expect(find.text('Patient is stable'), findsOneWidget);
    });

    testWidgets('an unprovided value with notAddedText renders that instead', (tester) async {
      await pumpApp(tester, const PatientTextCard(title: 'Destination', text: '', notAddedText: 'Not added by EMS yet'));

      expect(find.text('Not added by EMS yet'), findsOneWidget);
    });

    testWidgets('an unprovided value with no notAddedText renders empty', (tester) async {
      await pumpApp(tester, const PatientTextCard(title: 'Destination', text: null));

      expect(find.text('Destination'), findsOneWidget);
    });
  });

  group('PatientVitalsCard', () {
    testWidgets('shows "No upload history recorded" while history is empty', (tester) async {
      final firestore = FakeFirebaseFirestore();
      await pumpApp(
        tester,
        PatientVitalsCard(patient: _patient()),
        overrides: [firestoreProvider.overrideWithValue(firestore)],
      );
      await tester.pump();

      expect(find.text('No upload history recorded for this patient'), findsOneWidget);
    });

    testWidgets('shows the "Recorded" stamp once history has at least one entry', (tester) async {
      final firestore = FakeFirebaseFirestore();
      await firestore
          .collection('patients')
          .doc('patient-1')
          .collection('vitalsHistory')
          .add({'heartRate': 95, 'bloodPressure': '120/80', 'recordedAt': Timestamp.now()});

      await pumpApp(
        tester,
        PatientVitalsCard(patient: _patient()),
        overrides: [firestoreProvider.overrideWithValue(firestore)],
      );
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Recorded'), findsOneWidget);
    });

    testWidgets('tapping the Blood Pressure trend icon opens a dialog with real systolic/diastolic data', (
      tester,
    ) async {
      // Confirms PatientVitalsCard's own embedded VitalSeries selectors
      // (systolic/diastolic bloodPressurePart(...) closures) actually run
      // for real, not just get constructed — PatientInfoChip's own trend-
      // icon test elsewhere in this file only exercises a locally-defined
      // test series, never these specific closures.
      final firestore = FakeFirebaseFirestore();
      await firestore
          .collection('patients')
          .doc('patient-1')
          .collection('vitalsHistory')
          .add({'heartRate': 90, 'bloodPressure': '118/76', 'recordedAt': Timestamp.fromDate(DateTime(2024, 1, 1, 8))});
      await firestore
          .collection('patients')
          .doc('patient-1')
          .collection('vitalsHistory')
          .add({'heartRate': 95, 'bloodPressure': '122/82', 'recordedAt': Timestamp.fromDate(DateTime(2024, 1, 1, 9))});

      await pumpApp(
        tester,
        PatientVitalsCard(patient: _patient()),
        overrides: [firestoreProvider.overrideWithValue(firestore)],
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('vitals_trend_Blood Pressure')));
      await tester.pumpAndSettle();

      expect(find.text('Systolic'), findsOneWidget);
      expect(find.text('Diastolic'), findsOneWidget);
      expect(find.text('Not enough recorded data yet to show a trend.'), findsNothing);
    });

    testWidgets('a patient with no id renders with empty history, no crash', (tester) async {
      final firestore = FakeFirebaseFirestore();
      await pumpApp(
        tester,
        PatientVitalsCard(patient: _patient(id: null)),
        overrides: [firestoreProvider.overrideWithValue(firestore)],
      );
      await tester.pump();

      expect(find.text('No upload history recorded for this patient'), findsOneWidget);
    });
  });
}

extension _PatientTestFields on Patient {
  Patient copyWithTestFields({String? treatment, String? ivSize, String? ivPlacement}) {
    return Patient(
      id: id,
      name: name,
      healthcareNumber: healthcareNumber,
      gender: gender,
      age: age,
      vitals: vitals,
      treatment: treatment,
      ivSize: ivSize,
      ivPlacement: ivPlacement,
    );
  }
}
