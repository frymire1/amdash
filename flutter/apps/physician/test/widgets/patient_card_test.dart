import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physician/services/ems_location_service.dart';
import 'package:physician/widgets/patient_card.dart';

import '../support/pump_app.dart';

const _patient = Patient(
  id: 'patient-1',
  name: PatientField.resolved('Alex Rivera'),
  gender: 'M',
  age: 34,
  healthcareNumber: PatientField.resolved('HC-123'),
  vitals: PatientVitals(heartRate: 80, bloodPressure: '120/80', oxygen: 98, temperature: 37.0),
  destination: 'Ottawa General',
);

void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    Patient patient = _patient,
    EmsTrackingStatus trackingStatus = EmsTrackingStatus.active,
    double? distanceToHospitalMeters,
    VoidCallback? onTap,
  }) {
    return pumpApp(
      tester,
      PatientCard(
        patient: patient,
        trackingStatus: trackingStatus,
        distanceToHospitalMeters: distanceToHospitalMeters,
        onTap: onTap ?? () {},
      ),
    );
  }

  testWidgets('active + a known distance: shows the pulsing pill and the distance line', (tester) async {
    await pumpCard(tester, distanceToHospitalMeters: 450);
    // Never pumpAndSettle() — the active pill pulses forever.
    await tester.pump();
    await tester.pump();

    expect(find.text('TRACKING ONLINE'), findsOneWidget);
    expect(find.text('450 m from hospital'), findsOneWidget);
  });

  testWidgets('a distance of 1000m or more is shown in km, one decimal', (tester) async {
    await pumpCard(tester, distanceToHospitalMeters: 2350);
    await tester.pump();
    await tester.pump();

    expect(find.text('2.4 km from hospital'), findsOneWidget);
  });

  testWidgets('active with no distance known: omits the distance line', (tester) async {
    await pumpCard(tester);
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('from hospital'), findsNothing);
  });

  testWidgets('stale: shows "Lost Connection" and hides distance even if provided', (tester) async {
    await pumpCard(tester, trackingStatus: EmsTrackingStatus.stale, distanceToHospitalMeters: 200);
    await tester.pumpAndSettle();

    expect(find.text('LOST CONNECTION'), findsOneWidget);
    expect(find.textContaining('from hospital'), findsNothing);
  });

  testWidgets('noData: shows "Tracking Offline"', (tester) async {
    await pumpCard(tester, trackingStatus: EmsTrackingStatus.noData);
    await tester.pumpAndSettle();

    expect(find.text('TRACKING OFFLINE'), findsOneWidget);
  });

  testWidgets('loading: shows the neutral "Tracking…" placeholder', (tester) async {
    await pumpCard(tester, trackingStatus: EmsTrackingStatus.loading);
    await tester.pumpAndSettle();

    expect(find.text('TRACKING…'), findsOneWidget);
  });

  testWidgets('unprovided gender/age/destination fall back to "Not added yet"', (tester) async {
    const patient = Patient(
      id: 'patient-1',
      name: PatientField.resolved('Alex Rivera'),
      gender: 'Unknown',
      age: 'Unknown',
      healthcareNumber: PatientField.resolved('HC-123'),
      vitals: PatientVitals(heartRate: null, bloodPressure: '', oxygen: null, temperature: null),
    );
    await pumpCard(tester, patient: patient, trackingStatus: EmsTrackingStatus.noData);
    await tester.pumpAndSettle();

    expect(find.text('Not added yet · Not added yet'), findsOneWidget);
    expect(find.text('Destination: Not added yet'), findsOneWidget);
  });

  testWidgets('tapping the card invokes onTap', (tester) async {
    var tapped = false;
    await pumpCard(tester, trackingStatus: EmsTrackingStatus.noData, onTap: () => tapped = true);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PatientCard));
    await tester.pumpAndSettle();

    expect(tapped, isTrue);
  });
}
