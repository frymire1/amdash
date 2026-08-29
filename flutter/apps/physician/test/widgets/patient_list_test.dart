import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physician/classes/active_location.dart';
import 'package:physician/services/ems_location_service.dart';
import 'package:physician/services/patient_service.dart';
import 'package:physician/widgets/patient_card.dart';
import 'package:physician/widgets/patient_list.dart';

import '../support/pump_app.dart';

// Same minimal fake as patient_viewer_test.dart's.
class _FakeEmsLocationController extends EmsLocationController {
  _FakeEmsLocationController(this._initial);
  final EmsLocationState _initial;

  @override
  EmsLocationState build() => _initial;
}

Patient _patient(String id, {String destination = 'Ottawa Civic'}) {
  return Patient(
    id: id,
    name: PatientField.resolved('Patient $id'),
    gender: 'Female',
    age: 42,
    healthcareNumber: const PatientField.resolved('HC-1'),
    vitals: const PatientVitals(heartRate: 90, bloodPressure: '120/80', oxygen: 98, temperature: 37),
    destination: destination,
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
const _general = Hospital(
  id: 'hosp-2',
  name: 'Ottawa General',
  address: '501 Smyth Rd',
  latitude: 45.41,
  longitude: -75.66,
  organizationId: 'org-1',
);

void main() {
  Future<void> pumpList(
    WidgetTester tester, {
    AsyncValue<List<Patient>> patients = const AsyncValue.data([]),
    List<Hospital> hospitals = const [],
    UserProfile? profile,
    EmsLocationState emsState = const EmsLocationState(hasLoadedOnce: true),
    ValueChanged<Patient>? onSelected,
  }) {
    return pumpApp(
      tester,
      PatientList(onSelected: onSelected ?? (_) {}),
      overrides: [
        physicianPatientsProvider.overrideWithValue(patients),
        hospitalsProvider.overrideWith((ref) => Stream.value(hospitals)),
        userProfileProvider.overrideWith((ref) => Stream.value(profile)),
        emsLocationProvider.overrideWith(() => _FakeEmsLocationController(emsState)),
      ],
    );
  }

  testWidgets('before the first snapshot: shows a spinner', (tester) async {
    await pumpList(tester, patients: const AsyncValue.loading());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('loaded with no patients at all: shows the "no patients uploaded" empty state', (tester) async {
    await pumpList(
      tester,
      patients: const AsyncValue.data([]),
      hospitals: const [_civic],
      profile: const UserProfile(workLocation: 'Ottawa Civic'),
    );
    await tester.pumpAndSettle();

    expect(find.text('No patients uploaded yet'), findsOneWidget);
  });

  testWidgets('defaults the destination filter to the physician\'s own work location', (tester) async {
    await pumpList(
      tester,
      patients: AsyncValue.data([_patient('p1'), _patient('p2', destination: 'Ottawa General')]),
      hospitals: const [_civic, _general],
      profile: const UserProfile(workLocation: 'Ottawa Civic'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Currently showing patients en route to Ottawa Civic'), findsOneWidget);
    expect(find.byType(PatientCard), findsOneWidget);
  });

  testWidgets('falls back to the first hospital when the work location matches none', (tester) async {
    await pumpList(
      tester,
      patients: AsyncValue.data([_patient('p1', destination: 'Ottawa General')]),
      hospitals: const [_general],
      profile: const UserProfile(workLocation: 'Somewhere Else'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Currently showing patients en route to Ottawa General'), findsOneWidget);
  });

  testWidgets('no patients match the current filter: shows the filtered-empty state', (tester) async {
    await pumpList(
      tester,
      patients: AsyncValue.data([_patient('p1', destination: 'Ottawa General')]),
      hospitals: const [_civic, _general],
      profile: const UserProfile(workLocation: 'Ottawa Civic'),
    );
    await tester.pumpAndSettle();

    expect(find.text('No patients match this filter'), findsOneWidget);
    expect(find.text('Try a different destination'), findsOneWidget);
  });

  testWidgets('opening the filter panel shows the destination dropdown and sort checkbox', (tester) async {
    await pumpList(
      tester,
      patients: AsyncValue.data([_patient('p1')]),
      hospitals: const [_civic, _general],
      profile: const UserProfile(workLocation: 'Ottawa Civic'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();

    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    expect(find.text('Sort by distance from my hospital'), findsOneWidget);
  });

  testWidgets('picking a different destination re-filters and marks the filter active', (tester) async {
    await pumpList(
      tester,
      patients: AsyncValue.data([_patient('p1'), _patient('p2', destination: 'Ottawa General')]),
      hospitals: const [_civic, _general],
      profile: const UserProfile(workLocation: 'Ottawa Civic'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ottawa General').last);
    await tester.pumpAndSettle();

    expect(find.text('Currently showing patients en route to Ottawa General'), findsOneWidget);
    // filterActive now true (selected != workLocation) — the filter icon
    // switches to the brand color; hard to assert color directly, so this
    // instead just confirms the underlying state actually changed.
    expect(find.byType(PatientCard), findsOneWidget);
  });

  testWidgets('sort by distance orders tracked-with-fix patients ahead of ones with no fix', (tester) async {
    // The default 600px-tall test surface only fits 2 of these 3 cards
    // once the filter panel is open — taller here so ListView.builder
    // actually lays out (and this test can see) all three.
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpList(
      tester,
      patients: AsyncValue.data([_patient('far'), _patient('near'), _patient('untracked')]),
      hospitals: const [_civic],
      profile: const UserProfile(workLocation: 'Ottawa Civic'),
      emsState: const EmsLocationState(
        hasLoadedOnce: true,
        info: {
          'far': EmsTrackingInfo(
            status: EmsTrackingStatus.active,
            location: ActiveLocation(patientId: 'far', updatedAtMs: 0, latitude: 46.0, longitude: -76.5),
          ),
          'near': EmsTrackingInfo(
            status: EmsTrackingStatus.active,
            location: ActiveLocation(patientId: 'near', updatedAtMs: 0, latitude: 45.41, longitude: -75.76),
          ),
        },
      ),
    );
    // Never pumpAndSettle() from here on — the two "active" tracking pills
    // pulse forever.
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Sort by distance from my hospital'));
    await tester.pump();
    await tester.pump();

    final names = tester
        .widgetList<PatientCard>(find.byType(PatientCard))
        .map((c) => c.patient.id)
        .toList();
    expect(names, ['near', 'far', 'untracked']);
  });

  testWidgets('tapping a patient card invokes onSelected with that patient', (tester) async {
    Patient? selected;
    await pumpList(
      tester,
      patients: AsyncValue.data([_patient('p1')]),
      hospitals: const [_civic],
      profile: const UserProfile(workLocation: 'Ottawa Civic'),
      onSelected: (p) => selected = p,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PatientCard));
    await tester.pumpAndSettle();

    expect(selected?.id, 'p1');
  });
}
