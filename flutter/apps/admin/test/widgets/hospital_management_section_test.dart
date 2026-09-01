import 'package:admin/services/admin_service.dart';
import 'package:admin/widgets/hospital_management_section.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockAdminService extends Mock implements AdminService {}

const _civic = Hospital(
  id: 'hosp-1',
  name: 'Ottawa Civic',
  address: '1053 Carling Ave',
  latitude: 45.40,
  longitude: -75.75,
  organizationId: 'org-1',
);

void main() {
  late _MockAdminService adminService;

  setUp(() {
    adminService = _MockAdminService();
  });

  Future<void> pumpSection(WidgetTester tester, {List<Hospital> hospitals = const []}) {
    // Always embedded inside AdminPage's own SingleChildScrollView in
    // production (hospital_management_screen.dart) — replicated here so
    // the add-hospital form + table don't overflow the test viewport.
    return pumpApp(
      tester,
      const SingleChildScrollView(child: HospitalManagementSection()),
      overrides: [
        adminServiceProvider.overrideWithValue(adminService),
        hospitalsProvider.overrideWith((ref) => Stream.value(hospitals)),
      ],
    );
  }

  testWidgets('no hospitals yet: shows the empty state', (tester) async {
    await pumpSection(tester);
    await tester.pumpAndSettle();

    expect(find.text('No hospitals yet'), findsOneWidget);
  });

  testWidgets('hospitals render as table rows', (tester) async {
    await pumpSection(tester, hospitals: const [_civic]);
    await tester.pumpAndSettle();

    expect(find.text('Ottawa Civic'), findsOneWidget);
    expect(find.text('1053 Carling Ave'), findsOneWidget);
  });

  testWidgets('creating with an empty field is a no-op', (tester) async {
    await pumpSection(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_hospital_submit')));
    await tester.pumpAndSettle();

    verifyNever(() => adminService.createHospital(name: any(named: 'name'), address: any(named: 'address')));
  });

  testWidgets('creating a hospital clears the form and shows the success message', (tester) async {
    when(
      () => adminService.createHospital(name: any(named: 'name'), address: any(named: 'address')),
    ).thenAnswer((_) async => _civic);

    await pumpSection(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Ottawa Civic');
    await tester.enterText(find.widgetWithText(TextField, 'Address'), '1053 Carling Ave');
    await tester.tap(find.byKey(const Key('add_hospital_submit')));
    await tester.pumpAndSettle();

    verify(() => adminService.createHospital(name: 'Ottawa Civic', address: '1053 Carling Ave')).called(1);
    expect(find.text('Hospital added.'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Ottawa Civic'), findsNothing);
  });

  testWidgets('a create failure with a short server message shows it verbatim', (tester) async {
    when(
      () => adminService.createHospital(name: any(named: 'name'), address: any(named: 'address')),
    ).thenThrow(Exception('message: invalid address'));

    await pumpSection(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'X');
    await tester.enterText(find.widgetWithText(TextField, 'Address'), 'Y');
    await tester.tap(find.byKey(const Key('add_hospital_submit')));
    await tester.pumpAndSettle();

    expect(find.textContaining('invalid address'), findsOneWidget);
  });

  testWidgets('a create failure with a long, opaque message shows the fallback', (tester) async {
    when(
      () => adminService.createHospital(name: any(named: 'name'), address: any(named: 'address')),
    ).thenThrow(Exception('x' * 200));

    await pumpSection(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'X');
    await tester.enterText(find.widgetWithText(TextField, 'Address'), 'Y');
    await tester.tap(find.byKey(const Key('add_hospital_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Failed to add hospital. Please check the address and try again.'), findsOneWidget);
  });

  testWidgets('tapping edit opens the edit dialog prefilled with that hospital', (tester) async {
    await pumpSection(tester, hospitals: const [_civic]);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('edit_hospital_Ottawa Civic')));
    await tester.pumpAndSettle();

    expect(find.text('Edit Hospital'), findsOneWidget);
  });

  testWidgets('deleting a hospital calls the service', (tester) async {
    when(() => adminService.deleteHospital(any())).thenAnswer((_) async {});

    await pumpSection(tester, hospitals: const [_civic]);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete_hospital_Ottawa Civic')));
    await tester.pumpAndSettle();

    verify(() => adminService.deleteHospital('hosp-1')).called(1);
  });

  testWidgets('a delete failure shows a snackbar', (tester) async {
    when(() => adminService.deleteHospital(any())).thenThrow(Exception('message: in use'));

    await pumpSection(tester, hospitals: const [_civic]);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete_hospital_Ottawa Civic')));
    await tester.pumpAndSettle();

    expect(find.textContaining('in use'), findsOneWidget);
  });
}
