import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physician/screens/main_view_screen.dart';
import 'package:physician/services/ambulance_location_service.dart';
import 'package:physician/services/ems_location_service.dart';
import 'package:physician/services/patient_service.dart';
import 'package:physician/widgets/multiple_ambulance_view.dart';
import 'package:physician/widgets/patient_card.dart';
import 'package:physician/widgets/patient_list.dart';
import 'package:physician/widgets/patient_viewer.dart';

import '../support/mock_google_maps.dart';
import '../support/pump_app.dart';

class _FakeEmsLocationController extends EmsLocationController {
  @override
  EmsLocationState build() => const EmsLocationState(hasLoadedOnce: true);
}

class _FakeAmbulanceLocationController extends AmbulanceLocationController {
  _FakeAmbulanceLocationController([this._initial = const AmbulanceLocationState(hasLoadedOnce: true)]);
  final AmbulanceLocationState _initial;

  @override
  AmbulanceLocationState build() => _initial;
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
  setUpAll(() {
    registerGoogleMapsFallbackValues();
  });

  setUp(() {
    installMockGoogleMaps();
  });

  Future<ProviderContainer> pumpScreen(
    WidgetTester tester, {
    List<Patient> patients = const [],
    Organization? organization,
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
        ownOrganizationProvider.overrideWith((ref) => Stream.value(organization)),
        ambulanceLocationProvider.overrideWith(_FakeAmbulanceLocationController.new),
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
        ownOrganizationProvider.overrideWith((ref) => Stream.value(null)),
        ambulanceLocationProvider.overrideWith(_FakeAmbulanceLocationController.new),
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

  group('multiple ambulance view mode', () {
    testWidgets('the view-mode control never shows when the org flag is off', (tester) async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('All Ambulances'), findsNothing);
      expect(find.text('Transporting'), findsNothing);
      expect(find.byType(PatientList), findsOneWidget);
    });

    testWidgets('the view-mode control shows once the org flag is on, defaulting to Patients', (tester) async {
      await pumpScreen(
        tester,
        organization: const Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true),
      );
      await tester.pumpAndSettle();

      expect(find.text('All Ambulances'), findsOneWidget);
      expect(find.text('Transporting'), findsOneWidget);
      expect(find.byType(PatientList), findsOneWidget);
      expect(find.byType(MultipleAmbulanceView), findsNothing);
    });

    testWidgets('selecting "All Ambulances" swaps the body for MultipleAmbulanceView(filter: all)', (tester) async {
      await pumpScreen(
        tester,
        organization: const Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('All Ambulances'));
      await tester.pumpAndSettle();

      expect(find.byType(PatientList), findsNothing);
      final view = tester.widget<MultipleAmbulanceView>(find.byType(MultipleAmbulanceView));
      expect(view.filter, AmbulanceViewFilter.all);
    });

    testWidgets('selecting "Transporting" swaps the body for MultipleAmbulanceView(filter: transportingOnly)', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        organization: const Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Transporting'));
      await tester.pumpAndSettle();

      final view = tester.widget<MultipleAmbulanceView>(find.byType(MultipleAmbulanceView));
      expect(view.filter, AmbulanceViewFilter.transportingOnly);
    });

    testWidgets('switching back to "Patients" restores the normal list/viewer body', (tester) async {
      await pumpScreen(
        tester,
        organization: const Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('All Ambulances'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Patients'));
      await tester.pumpAndSettle();

      expect(find.byType(PatientList), findsOneWidget);
      expect(find.byType(MultipleAmbulanceView), findsNothing);
    });
  });
}
