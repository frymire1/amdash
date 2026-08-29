import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

const _fullVitals = PatientVitals(
  heartRate: 95,
  bloodPressure: '120/80',
  oxygen: 98,
  temperature: 37.1,
  respiratoryRate: 16,
  gcs: 15,
);

const _blankVitals = PatientVitals(
  heartRate: 'Unknown',
  bloodPressure: '',
  oxygen: 'Unknown',
  temperature: 'Unknown',
);

void main() {
  testWidgets('renders every field with its suffix, exactly matching the e2e-relied-upon "95 bpm" format', (
    tester,
  ) async {
    await pumpApp(tester, const PatientVitalsChips(vitals: _fullVitals));

    expect(find.text('95 bpm'), findsOneWidget);
    expect(find.text('120/80'), findsOneWidget);
    expect(find.text('98 %'), findsOneWidget);
    expect(find.text('16 breaths/min'), findsOneWidget);
    expect(find.text('37.1 °C'), findsOneWidget);
    expect(find.text('15'), findsOneWidget);
  });

  testWidgets('the EMS blank-field sentinel and truly-empty values all render "Not added yet", italicized', (
    tester,
  ) async {
    await pumpApp(tester, const PatientVitalsChips(vitals: _blankVitals));

    expect(find.text('Not added yet'), findsNWidgets(6));
    final texts = tester.widgetList<Text>(find.text('Not added yet'));
    for (final text in texts) {
      expect(text.style!.fontStyle, FontStyle.italic);
    }
  });

  testWidgets('a provided value is not italicized', (tester) async {
    await pumpApp(tester, const PatientVitalsChips(vitals: _fullVitals));

    final heartRateText = tester.widget<Text>(find.text('95 bpm'));
    expect(heartRateText.style!.fontStyle, FontStyle.normal);
  });
}
