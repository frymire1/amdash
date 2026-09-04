import 'package:amdash_core/amdash_core.dart';
import 'package:ems/classes/uploaded_patient.dart';
import 'package:ems/screens/patient_viewer_screen.dart';
import 'package:ems/services/battery_watch_service.dart';
import 'package:ems/services/patient_session_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

// This screen doesn't otherwise touch tracking at all (unlike
// patient_upload_screen.dart/home_screen.dart, which already fake out
// emsTrackingProvider directly) — BatteryWarningBanner's own
// batteryWatchProvider transitively reads emsTrackingProvider, which would
// otherwise hit a real, un-mocked FirebaseFunctions.instanceFor(...) and
// throw [core/no-app]. Faking batteryWatchProvider itself directly (rather
// than emsTrackingProvider) keeps this screen's own tests decoupled from a
// dependency they have no other reason to know about.
class _FakeBatteryWatchController extends BatteryWatchController {
  @override
  bool build() => false;
}

const _fullPatient = Patient(
  id: 'patient-1',
  name: PatientField.resolved('Alex Rivera'),
  gender: 'M',
  age: 34,
  healthcareNumber: PatientField.resolved('HC-123'),
  vitals: PatientVitals(heartRate: 80, bloodPressure: '120/80', oxygen: 98, temperature: 37.0),
  destination: 'Ottawa General',
  notes: 'Allergic to penicillin.',
);

void main() {
  Future<void> pumpScreen(
    WidgetTester tester, {
    AsyncValue<List<UploadedPatient>> patients = const AsyncValue.data([]),
    bool isOffline = false,
  }) {
    return pumpApp(
      tester,
      const SizedBox(),
      overrides: [
        uploadedPatientsProvider.overrideWithValue(patients),
        isOfflineProvider.overrideWithValue(isOffline),
        batteryWatchProvider.overrideWith(_FakeBatteryWatchController.new),
      ],
      routes: {'/patient/patient-1': (_) => const PatientViewerScreen(patientId: 'patient-1')},
      initialLocation: '/patient/patient-1',
    );
  }

  testWidgets('still loading (no cached value yet): shows a spinner', (tester) async {
    await pumpScreen(tester, patients: const AsyncValue.loading());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('settled with no matching patient: shows the empty state', (tester) async {
    await pumpScreen(tester, patients: const AsyncValue.data([]));
    await tester.pumpAndSettle();

    expect(find.text('This patient is no longer available'), findsOneWidget);
  });

  testWidgets('a matching patient renders its full details', (tester) async {
    await pumpScreen(
      tester,
      patients: const AsyncValue.data([UploadedPatient(id: 'patient-1', patient: _fullPatient)]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.textContaining('34 years'), findsOneWidget);
    expect(find.textContaining('M'), findsWidgets);
    expect(find.text('Healthcare #: HC-123'), findsOneWidget);
    expect(find.text('Allergic to penicillin.'), findsOneWidget);
  });

  testWidgets('missing age/gender fall back to "unknown"', (tester) async {
    const patient = Patient(
      id: 'patient-1',
      name: PatientField.resolved('Alex Rivera'),
      gender: 'Unknown',
      age: 'Unknown',
      healthcareNumber: PatientField.resolved(''),
      vitals: PatientVitals(heartRate: null, bloodPressure: '', oxygen: null, temperature: null),
    );
    await pumpScreen(
      tester,
      patients: const AsyncValue.data([UploadedPatient(id: 'patient-1', patient: patient)]),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Age: '), findsOneWidget);
    expect(find.textContaining('Gender: '), findsOneWidget);
    expect(find.text('Not added by EMS yet'), findsWidgets);
  });

  testWidgets('no notes: the Patient Notes card is omitted entirely', (tester) async {
    const patient = Patient(
      id: 'patient-1',
      name: PatientField.resolved('Alex Rivera'),
      gender: 'M',
      age: 34,
      healthcareNumber: PatientField.resolved('HC-123'),
      vitals: PatientVitals(heartRate: 80, bloodPressure: '120/80', oxygen: 98, temperature: 37.0),
    );
    await pumpScreen(
      tester,
      patients: const AsyncValue.data([UploadedPatient(id: 'patient-1', patient: patient)]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Patient Notes'), findsNothing);
  });

  testWidgets('tapping back with nothing to pop navigates home', (tester) async {
    await pumpScreen(tester, patients: const AsyncValue.data([]));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byKey(pumpAppHomeKey), findsOneWidget);
  });

  testWidgets('being offline shows the offline banner', (tester) async {
    await pumpScreen(tester, patients: const AsyncValue.data([]), isOffline: true);
    await tester.pumpAndSettle();

    expect(find.textContaining('offline'), findsWidgets);
  });
}
