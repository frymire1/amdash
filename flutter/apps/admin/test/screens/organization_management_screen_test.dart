import 'package:admin/screens/organization_management_screen.dart';
import 'package:admin/services/admin_service.dart';
import 'package:admin/services/organization_service.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockAdminService extends Mock implements AdminService {}

const _org = Organization(id: 'org-1', name: 'Acme Health', country: 'CA');

void main() {
  late _MockAdminService adminService;

  setUp(() {
    adminService = _MockAdminService();
  });

  Future<void> pumpScreen(WidgetTester tester, {List<Organization> organizations = const []}) {
    return pumpApp(
      tester,
      const OrganizationManagementScreen(),
      overrides: [
        adminServiceProvider.overrideWithValue(adminService),
        organizationsProvider.overrideWith((ref) => Stream.value(organizations)),
      ],
    );
  }

  testWidgets('no organizations yet: shows the empty state', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('No organizations yet'), findsOneWidget);
  });

  testWidgets('organizations render as table rows with their country name', (tester) async {
    await pumpScreen(tester, organizations: const [_org]);
    await tester.pumpAndSettle();

    expect(find.text('Acme Health'), findsOneWidget);
    expect(find.text('Canada'), findsOneWidget);
  });

  testWidgets('an organization with no country set shows "Not set"', (tester) async {
    await pumpScreen(
      tester,
      organizations: const [Organization(id: 'org-2', name: 'No Country Org')],
    );
    await tester.pumpAndSettle();

    expect(find.text('Not set'), findsOneWidget);
  });

  testWidgets('creating with an incomplete form is a no-op', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Create Organization'));
    await tester.pumpAndSettle();

    verifyNever(
      () => adminService.createOrganization(
        organizationName: any(named: 'organizationName'),
        adminEmail: any(named: 'adminEmail'),
        adminFirstName: any(named: 'adminFirstName'),
        adminLastName: any(named: 'adminLastName'),
        country: any(named: 'country'),
      ),
    );
  });

  testWidgets('creating successfully clears the form and shows the success message', (tester) async {
    when(
      () => adminService.createOrganization(
        organizationName: any(named: 'organizationName'),
        adminEmail: any(named: 'adminEmail'),
        adminFirstName: any(named: 'adminFirstName'),
        adminLastName: any(named: 'adminLastName'),
        country: any(named: 'country'),
      ),
    ).thenAnswer((_) async {});

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Organization Name'), 'Acme Health');
    await tester.enterText(find.widgetWithText(TextField, 'Admin Email'), 'admin@acme.example');
    await tester.enterText(find.widgetWithText(TextField, 'Admin First Name'), 'Jordan');
    await tester.enterText(find.widgetWithText(TextField, 'Admin Last Name'), 'Lee');
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Country'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Canada').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create Organization'));
    await tester.pumpAndSettle();

    verify(
      () => adminService.createOrganization(
        organizationName: 'Acme Health',
        adminEmail: 'admin@acme.example',
        adminFirstName: 'Jordan',
        adminLastName: 'Lee',
        country: 'CA',
      ),
    ).called(1);
    expect(find.text('Organization created.'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Acme Health'), findsNothing);
  });

  testWidgets('a create failure with a short server message shows it verbatim', (tester) async {
    when(
      () => adminService.createOrganization(
        organizationName: any(named: 'organizationName'),
        adminEmail: any(named: 'adminEmail'),
        adminFirstName: any(named: 'adminFirstName'),
        adminLastName: any(named: 'adminLastName'),
        country: any(named: 'country'),
      ),
    ).thenThrow(Exception('message: email already in use'));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Organization Name'), 'Acme Health');
    await tester.enterText(find.widgetWithText(TextField, 'Admin Email'), 'admin@acme.example');
    await tester.enterText(find.widgetWithText(TextField, 'Admin First Name'), 'Jordan');
    await tester.enterText(find.widgetWithText(TextField, 'Admin Last Name'), 'Lee');
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Country'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Canada').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create Organization'));
    await tester.pumpAndSettle();

    expect(find.textContaining('email already in use'), findsOneWidget);
  });

  testWidgets('a create failure with a long, opaque message shows the fallback', (tester) async {
    when(
      () => adminService.createOrganization(
        organizationName: any(named: 'organizationName'),
        adminEmail: any(named: 'adminEmail'),
        adminFirstName: any(named: 'adminFirstName'),
        adminLastName: any(named: 'adminLastName'),
        country: any(named: 'country'),
      ),
    ).thenThrow(Exception('x' * 200));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Organization Name'), 'Acme Health');
    await tester.enterText(find.widgetWithText(TextField, 'Admin Email'), 'admin@acme.example');
    await tester.enterText(find.widgetWithText(TextField, 'Admin First Name'), 'Jordan');
    await tester.enterText(find.widgetWithText(TextField, 'Admin Last Name'), 'Lee');
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Country'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Canada').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create Organization'));
    await tester.pumpAndSettle();

    expect(find.text('Failed to create organization.'), findsOneWidget);
  });
}
