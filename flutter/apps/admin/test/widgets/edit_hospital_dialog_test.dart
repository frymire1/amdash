import 'package:admin/services/admin_service.dart';
import 'package:admin/widgets/edit_hospital_dialog.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockAdminService extends Mock implements AdminService {}

const _hospital = Hospital(
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

  Future<void> pumpDialog(WidgetTester tester) {
    return pumpApp(
      tester,
      Builder(
        builder: (context) => FilledButton(
          onPressed: () => showEditHospitalDialog(context, _hospital),
          child: const Text('Open'),
        ),
      ),
      overrides: [adminServiceProvider.overrideWithValue(adminService)],
    );
  }

  testWidgets('prefills the name and address fields', (tester) async {
    await pumpDialog(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Ottawa Civic'), findsOneWidget);
    expect(find.widgetWithText(TextField, '1053 Carling Ave'), findsOneWidget);
  });

  testWidgets('closing does not save', (tester) async {
    await pumpDialog(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    verifyNever(() => adminService.updateHospital(hospitalId: any(named: 'hospitalId')));
    expect(find.text('Edit Hospital'), findsNothing);
  });

  testWidgets('saving with an empty name is a no-op', (tester) async {
    await pumpDialog(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Ottawa Civic'), '');
    await tester.tap(find.text('Save Changes'));
    await tester.pumpAndSettle();

    verifyNever(() => adminService.updateHospital(hospitalId: any(named: 'hospitalId')));
  });

  testWidgets('saving successfully shows the success message', (tester) async {
    when(
      () => adminService.updateHospital(
        hospitalId: any(named: 'hospitalId'),
        name: any(named: 'name'),
        address: any(named: 'address'),
      ),
    ).thenAnswer((_) async => _hospital);

    await pumpDialog(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Ottawa Civic'), 'Ottawa Civic Hospital');
    await tester.tap(find.text('Save Changes'));
    await tester.pumpAndSettle();

    verify(
      () => adminService.updateHospital(hospitalId: 'hosp-1', name: 'Ottawa Civic Hospital', address: '1053 Carling Ave'),
    ).called(1);
    expect(find.text('Saved.'), findsOneWidget);
  });

  testWidgets('a save failure with a short server message shows it verbatim', (tester) async {
    when(
      () => adminService.updateHospital(
        hospitalId: any(named: 'hospitalId'),
        name: any(named: 'name'),
        address: any(named: 'address'),
      ),
    ).thenThrow(Exception('message: bad address'));

    await pumpDialog(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save Changes'));
    await tester.pumpAndSettle();

    expect(find.textContaining('bad address'), findsOneWidget);
  });

  testWidgets('a save failure with a long, opaque message shows the fallback', (tester) async {
    when(
      () => adminService.updateHospital(
        hospitalId: any(named: 'hospitalId'),
        name: any(named: 'name'),
        address: any(named: 'address'),
      ),
    ).thenThrow(Exception('x' * 200));

    await pumpDialog(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save Changes'));
    await tester.pumpAndSettle();

    expect(find.text('Failed to save changes. Please check the address and try again.'), findsOneWidget);
  });
}
