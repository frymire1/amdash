import 'package:admin/classes/managed_user.dart';
import 'package:admin/screens/user_management_screen.dart';
import 'package:admin/services/admin_service.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockAdminService extends Mock implements AdminService {}

const _emsUser = ManagedUser(
  uid: 'uid-1',
  email: 'alex@example.com',
  firstName: 'Alex',
  lastName: 'Rivera',
  role: [UserRole.ems],
  disabled: false,
  hasPassword: true,
  mfaEnrolled: false,
);
const _physicianUser = ManagedUser(
  uid: 'uid-2',
  email: 'sam@example.com',
  firstName: 'Sam',
  lastName: 'Nguyen',
  role: [UserRole.physician],
  disabled: true,
  hasPassword: false,
  mfaEnrolled: true,
);

void main() {
  setUpAll(() {
    registerFallbackValue(UserRole.ems);
  });

  late _MockAdminService adminService;

  setUp(() {
    adminService = _MockAdminService();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    // AdminPage's own content maxes out at 960px — the default 800px test
    // surface is narrower than that and clips the Status column's pills.
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    return pumpApp(
      tester,
      const UserManagementScreen(),
      overrides: [adminServiceProvider.overrideWithValue(adminService)],
    );
  }

  testWidgets('loads and shows users on mount', (tester) async {
    when(() => adminService.listUsersWithRoles()).thenAnswer((_) async => [_emsUser, _physicianUser]);

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('alex@example.com'), findsOneWidget);
    expect(find.text('sam@example.com'), findsOneWidget);
  });

  testWidgets('a load failure shows the inline error', (tester) async {
    when(() => adminService.listUsersWithRoles()).thenThrow(Exception('boom'));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('Failed to load users. Please try again.'), findsOneWidget);
  });

  testWidgets('no users at all: shows the empty state', (tester) async {
    when(() => adminService.listUsersWithRoles()).thenAnswer((_) async => []);

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('No users yet'), findsOneWidget);
  });

  testWidgets('tapping refresh reloads the list', (tester) async {
    when(() => adminService.listUsersWithRoles()).thenAnswer((_) async => [_emsUser]);

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    verify(() => adminService.listUsersWithRoles()).called(2);
  });

  group('table rendering', () {
    testWidgets('an active user shows Active + MFA off pills and their role chip', (tester) async {
      when(() => adminService.listUsersWithRoles()).thenAnswer((_) async => [_emsUser]);

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('MFA OFF'), findsOneWidget);
      expect(find.text('ems'), findsOneWidget);
    });

    testWidgets('a suspended, invited, MFA-on user shows Suspended + MFA on pills', (tester) async {
      when(() => adminService.listUsersWithRoles()).thenAnswer((_) async => [_physicianUser]);

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('SUSPENDED'), findsOneWidget);
      expect(find.text('MFA ON'), findsOneWidget);
    });

    testWidgets('a user with no roles shows an Unassigned chip', (tester) async {
      const unassigned = ManagedUser(
        uid: 'uid-3',
        email: 'jordan@example.com',
        firstName: 'Jordan',
        lastName: 'Lee',
        role: [],
        disabled: false,
        hasPassword: true,
        mfaEnrolled: false,
      );
      when(() => adminService.listUsersWithRoles()).thenAnswer((_) async => [unassigned]);

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('Unassigned'), findsOneWidget);
    });

    testWidgets('tapping edit opens the edit dialog for that user', (tester) async {
      when(() => adminService.listUsersWithRoles()).thenAnswer((_) async => [_emsUser]);

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('edit_user_alex@example.com')));
      await tester.pumpAndSettle();

      expect(find.text('Edit User'), findsOneWidget);
    });
  });

  group('search and filter', () {
    setUp(() {
      when(() => adminService.listUsersWithRoles()).thenAnswer((_) async => [_emsUser, _physicianUser]);
    });

    testWidgets('searching by name or email narrows the table', (tester) async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Search'), 'sam');
      await tester.pumpAndSettle();

      expect(find.text('sam@example.com'), findsOneWidget);
      expect(find.text('alex@example.com'), findsNothing);
    });

    testWidgets('a search matching nothing shows the filtered-empty state', (tester) async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Search'), 'nobody');
      await tester.pumpAndSettle();

      expect(find.text('No users match this search'), findsOneWidget);
    });

    testWidgets('filtering by role narrows the table', (tester) async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(DropdownButtonFormField<UserRole?>, 'All roles'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('physician').last);
      await tester.pumpAndSettle();

      expect(find.text('sam@example.com'), findsOneWidget);
      expect(find.text('alex@example.com'), findsNothing);
    });
  });

  group('add user', () {
    testWidgets('creating with an incomplete form is a no-op', (tester) async {
      when(() => adminService.listUsersWithRoles()).thenAnswer((_) async => []);

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('add_user_submit')));
      await tester.pumpAndSettle();

      verifyNever(
        () => adminService.createUser(
          email: any(named: 'email'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          role: any(named: 'role'),
        ),
      );
    });

    testWidgets('creating successfully clears the form, shows the message, and refreshes the list', (tester) async {
      when(() => adminService.listUsersWithRoles()).thenAnswer((_) async => []);
      when(
        () => adminService.createUser(
          email: any(named: 'email'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          role: any(named: 'role'),
        ),
      ).thenAnswer((_) async => _emsUser);

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Email'), 'alex@example.com');
      await tester.enterText(find.widgetWithText(TextField, 'First Name'), 'Alex');
      await tester.enterText(find.widgetWithText(TextField, 'Last Name'), 'Rivera');
      await tester.tap(find.byKey(const Key('add_user_role_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add_user_role_option_ems')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add_user_submit')));
      await tester.pumpAndSettle();

      verify(
        () => adminService.createUser(email: 'alex@example.com', firstName: 'Alex', lastName: 'Rivera', role: UserRole.ems),
      ).called(1);
      expect(find.text('User created.'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'alex@example.com'), findsNothing);
      // Refreshed after create — listUsersWithRoles now returns the new
      // user, so the empty state is gone.
      verify(() => adminService.listUsersWithRoles()).called(2);
    });

    testWidgets('a create failure with a short server message shows it verbatim', (tester) async {
      when(() => adminService.listUsersWithRoles()).thenAnswer((_) async => []);
      when(
        () => adminService.createUser(
          email: any(named: 'email'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          role: any(named: 'role'),
        ),
      ).thenThrow(Exception('message: email already in use'));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Email'), 'alex@example.com');
      await tester.enterText(find.widgetWithText(TextField, 'First Name'), 'Alex');
      await tester.enterText(find.widgetWithText(TextField, 'Last Name'), 'Rivera');
      await tester.tap(find.byKey(const Key('add_user_role_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add_user_role_option_ems')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add_user_submit')));
      await tester.pumpAndSettle();

      expect(find.textContaining('email already in use'), findsOneWidget);
    });

    testWidgets('a create failure with a long, opaque message shows the fallback', (tester) async {
      when(() => adminService.listUsersWithRoles()).thenAnswer((_) async => []);
      when(
        () => adminService.createUser(
          email: any(named: 'email'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          role: any(named: 'role'),
        ),
      ).thenThrow(Exception('x' * 200));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Email'), 'alex@example.com');
      await tester.enterText(find.widgetWithText(TextField, 'First Name'), 'Alex');
      await tester.enterText(find.widgetWithText(TextField, 'Last Name'), 'Rivera');
      await tester.tap(find.byKey(const Key('add_user_role_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add_user_role_option_ems')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add_user_submit')));
      await tester.pumpAndSettle();

      expect(find.text('Failed to create user.'), findsOneWidget);
    });
  });
}
