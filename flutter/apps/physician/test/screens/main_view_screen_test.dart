import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physician/screens/main_view_screen.dart';
import 'package:physician/services/ems_location_service.dart';
import 'package:physician/services/patient_service.dart';
import 'package:physician/widgets/patient_card.dart';
import 'package:physician/widgets/patient_list.dart';
import 'package:physician/widgets/patient_viewer.dart';

import '../support/pump_app.dart';

class _FakeEmsLocationController extends EmsLocationController {
  @override
  EmsLocationState build() => const EmsLocationState(hasLoadedOnce: true);
}

Patient _patient(String id, String name) {
  return Patient(
    id: id,
    name: PatientField.resolved(name),
    gender: 'Female',
    age: 42,
    healthcareNumber: const PatientField.resolved('HC-1'),
    vitals: const PatientVitals(heartRate: 90, bloodPressure: '120/80', oxygen: 98, temperature: 37),
    destination: 'Ottawa Civic',
  );
}

const _civic = Hospital(
  id: 'hosp-1',
  name: 'Ottawa Civic',
  address: '1053 Carling Ave',
  latitude: 45.40,
  longitude: -75.75,
  organizationId: 'org-1',
);

void main() {
  Future<ProviderContainer> pumpScreen(
    WidgetTester tester, {
    List<Patient> patients = const [],
  }) async {
    late ProviderContainer container;
    await pumpApp(
      tester,
      Builder(
        builder: (context) {
          container = ProviderScope.containerOf(context);
          // Not const — a compile-time-const construction never registers a
          // runtime hit on the constructor's own declaration line.
          return MainViewScreen();
        },
      ),
      overrides: [
        physicianPatientsProvider.overrideWithValue(AsyncValue.data(patients)),
        hospitalsProvider.overrideWith((ref) => Stream.value(const [_civic])),
        userProfileProvider.overrideWith((ref) => Stream.value(const UserProfile(workLocation: 'Ottawa Civic'))),
        emsLocationProvider.overrideWith(_FakeEmsLocationController.new),
      ],
    );
    return container;
  }

  testWidgets('desktop width: list and viewer show side by side', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpScreen(tester, patients: [_patient('p1', 'Alex Rivera')]);
    await tester.pumpAndSettle();

    expect(find.byType(PatientList), findsOneWidget);
    expect(find.byType(PatientViewer), findsOneWidget);
    expect(find.text('Select a patient to view details'), findsOneWidget);
  });

  testWidgets('desktop width: selecting a patient updates the viewer pane', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpScreen(tester, patients: [_patient('p1', 'Alex Rivera')]);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PatientCard));
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: find.byType(PatientViewer), matching: find.text('Alex Rivera')),
      findsOneWidget,
    );
  });

  testWidgets(
    'desktop width: the viewer re-reads the selected patient from the live provider, not a frozen snapshot',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final container = await pumpScreen(tester, patients: [_patient('p1', 'Alex Rivera')]);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PatientCard));
      await tester.pumpAndSettle();

      container.updateOverrides([
        physicianPatientsProvider.overrideWithValue(AsyncValue.data([_patient('p1', 'Alex Rivera (updated)')])),
        hospitalsProvider.overrideWith((ref) => Stream.value(const [_civic])),
        userProfileProvider.overrideWith((ref) => Stream.value(const UserProfile(workLocation: 'Ottawa Civic'))),
        emsLocationProvider.overrideWith(_FakeEmsLocationController.new),
      ]);
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: find.byType(PatientViewer), matching: find.text('Alex Rivera (updated)')),
        findsOneWidget,
      );
    },
  );

  testWidgets('narrow width with nothing selected: shows only the list', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpScreen(tester, patients: [_patient('p1', 'Alex Rivera')]);
    await tester.pumpAndSettle();

    expect(find.byType(PatientList), findsOneWidget);
    expect(find.byType(PatientViewer), findsNothing);
  });

  testWidgets('narrow width: selecting a patient switches to the viewer, with a button back to the list', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpScreen(tester, patients: [_patient('p1', 'Alex Rivera')]);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PatientCard));
    await tester.pumpAndSettle();

    expect(find.byType(PatientList), findsNothing);
    expect(find.byType(PatientViewer), findsOneWidget);
    expect(find.text('Patient List'), findsOneWidget);

    await tester.tap(find.text('Patient List'));
    await tester.pumpAndSettle();

    expect(find.byType(PatientList), findsOneWidget);
    expect(find.byType(PatientViewer), findsNothing);
  });
}
