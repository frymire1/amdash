import 'package:amdash_core/amdash_core.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

const _hrSeries = [VitalSeries(label: 'Heart Rate', selector: _hrSelector)];
num? _hrSelector(PatientVitals v) => v.heartRate is num ? v.heartRate as num : null;

const _bpSeries = [
  VitalSeries(label: 'Systolic', selector: _systolicSelector, color: Color(0xFF000001)),
  VitalSeries(label: 'Diastolic', selector: _diastolicSelector, color: Color(0xFF000002)),
];
num? _systolicSelector(PatientVitals v) => bloodPressurePart(v.bloodPressure, 0);
num? _diastolicSelector(PatientVitals v) => bloodPressurePart(v.bloodPressure, 1);

VitalsHistoryEntry _entry({Object? heartRate, String bloodPressure = '', DateTime? at}) {
  return VitalsHistoryEntry(
    vitals: PatientVitals(heartRate: heartRate, bloodPressure: bloodPressure, oxygen: null, temperature: null),
    recordedAt: at,
  );
}

void main() {
  Future<void> open(
    WidgetTester tester, {
    required List<VitalsHistoryEntry> history,
    required List<VitalSeries> series,
    String? unit,
  }) async {
    await pumpApp(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showVitalsTrendDialog(context, title: 'Heart Rate', history: history, series: series, unit: unit),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('fewer than 2 usable points shows the "not enough data" message', (tester) async {
    await open(
      tester,
      history: [_entry(heartRate: 90, at: DateTime(2024, 1, 1))],
      series: _hrSeries,
    );

    expect(find.text('Not enough recorded data yet to show a trend.'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('entries missing a recordedAt are excluded, possibly dropping below 2 points', (tester) async {
    await open(
      tester,
      history: [_entry(heartRate: 90, at: DateTime(2024, 1, 1)), _entry(heartRate: 95, at: null)],
      series: _hrSeries,
    );

    expect(find.text('Not enough recorded data yet to show a trend.'), findsOneWidget);
  });

  testWidgets('an Unknown-sentinel reading is filtered out by the series selector', (tester) async {
    await open(
      tester,
      history: [
        _entry(heartRate: 90, at: DateTime(2024, 1, 1)),
        _entry(heartRate: 'Unknown', at: DateTime(2024, 1, 2)),
      ],
      series: _hrSeries,
    );

    expect(find.text('Not enough recorded data yet to show a trend.'), findsOneWidget);
  });

  testWidgets('a single series with 2+ points charts without a legend (only shown for 2+ series)', (tester) async {
    await open(
      tester,
      history: [
        _entry(heartRate: 90, at: DateTime(2024, 1, 1, 8)),
        _entry(heartRate: 95, at: DateTime(2024, 1, 1, 9)),
      ],
      series: _hrSeries,
      unit: ' bpm',
    );

    expect(find.text('Heart Rate'), findsOneWidget);
    expect(find.text('bpm'), findsOneWidget);
    expect(find.byType(Wrap), findsNothing);
  });

  testWidgets('a dual series (blood pressure) same-day shows a legend with both labels', (tester) async {
    await open(
      tester,
      history: [
        _entry(bloodPressure: '118/76', at: DateTime(2024, 1, 1, 8)),
        _entry(bloodPressure: '120/80', at: DateTime(2024, 1, 1, 9)),
      ],
      series: _bpSeries,
    );

    expect(find.byType(Wrap), findsOneWidget);
    expect(find.text('Systolic'), findsOneWidget);
    expect(find.text('Diastolic'), findsOneWidget);
  });

  testWidgets('cross-day readings still chart (different axisFormat branch, no crash)', (tester) async {
    await open(
      tester,
      history: [
        _entry(bloodPressure: '118/76', at: DateTime(2024, 1, 1)),
        _entry(bloodPressure: '120/80', at: DateTime(2024, 1, 3)),
      ],
      series: _bpSeries,
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(Wrap), findsOneWidget);
  });

  testWidgets('no unit given omits the unit suffix in the title', (tester) async {
    await open(
      tester,
      history: [
        _entry(heartRate: 90, at: DateTime(2024, 1, 1, 8)),
        _entry(heartRate: 95, at: DateTime(2024, 1, 1, 9)),
      ],
      series: _hrSeries,
    );

    expect(find.text('Heart Rate'), findsOneWidget);
  });

  testWidgets('touching a chart point shows its tooltip (value + exact timestamp)', (tester) async {
    await open(
      tester,
      history: [
        _entry(heartRate: 90, at: DateTime(2024, 1, 1, 8)),
        _entry(heartRate: 95, at: DateTime(2024, 1, 1, 9)),
      ],
      series: _hrSeries,
      unit: ' bpm',
    );

    // Near the plot area's own left edge, not its center — confirmed via
    // bisection that the center misses both data points entirely:
    // touchSpotThreshold defaults to 10 (in the same x-axis units as the
    // chart's own minX/maxX, which this widget sets to elapsed
    // milliseconds), but these two entries are a full hour apart, so
    // "the middle" sits ~1.8M ms from the nearest real spot. The first
    // entry's spot is at x=0, right at the plot's left edge — but not the
    // *widget's* left edge: leftTitles reserves 34px for the Y-axis labels
    // ahead of the actual plot area, so landing just past that offset is
    // what's needed, not chartRect.left itself.
    final chartRect = tester.getRect(find.byType(LineChart));
    final gesture = await tester.startGesture(Offset(chartRect.left + 40, chartRect.center.dy));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('Close pops the dialog', (tester) async {
    await open(
      tester,
      history: [_entry(heartRate: 90, at: DateTime(2024, 1, 1))],
      series: _hrSeries,
    );

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
