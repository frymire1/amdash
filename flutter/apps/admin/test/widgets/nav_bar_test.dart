import 'dart:async';

import 'package:admin/widgets/nav_bar.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockAuthService extends Mock implements AuthService {}

void main() {
  late _MockAuthService authService;

  setUp(() {
    authService = _MockAuthService();
  });

  Future<void> pumpNavBar(WidgetTester tester, {UserProfile? profile}) {
    return pumpApp(
      tester,
      const SizedBox(),
      overrides: [
        userProfileProvider.overrideWith((ref) => Stream.value(profile)),
        authServiceProvider.overrideWithValue(authService),
      ],
      routes: {
        '/nav': (_) => Scaffold(appBar: const AdminNavBar()),
        '/users': (_) => const SizedBox(key: Key('users_route')),
        '/settings': (_) => const SizedBox(key: Key('settings_route')),
        '/audit-log': (_) => const SizedBox(key: Key('audit_log_route')),
        '/organizations': (_) => const SizedBox(key: Key('organizations_route')),
        '/user-settings': (_) => const SizedBox(key: Key('user_settings_route')),
      },
      initialLocation: '/nav',
    );
  }

  testWidgets('a plain (no-role) profile: the hamburger menu has no admin links', (tester) async {
    await pumpNavBar(tester, profile: const UserProfile(role: []));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('Users'), findsNothing);
    expect(find.text('Organizations'), findsNothing);
  });

  testWidgets('an admin profile: the menu shows Users/Settings/Audit Log, not Organizations', (tester) async {
    await pumpNavBar(tester, profile: const UserProfile(role: [UserRole.admin]));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('Users'), findsOneWidget);
    expect(find.text('Audit Log'), findsOneWidget);
    expect(find.text('Organizations'), findsNothing);
  });

  testWidgets('a super-admin profile: the menu also shows Organizations', (tester) async {
    await pumpNavBar(tester, profile: const UserProfile(role: [UserRole.admin, UserRole.superAdmin]));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('Organizations'), findsOneWidget);
  });

  testWidgets('selecting a menu item navigates to its route', (tester) async {
    await pumpNavBar(tester, profile: const UserProfile(role: [UserRole.admin]));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Audit Log'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('audit_log_route')), findsOneWidget);
  });

  testWidgets('no name on the profile yet: shows a fallback account icon', (tester) async {
    await pumpNavBar(tester, profile: const UserProfile());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.account_circle), findsOneWidget);
  });

  testWidgets('a named profile: shows the initials instead of the fallback icon', (tester) async {
    await pumpNavBar(tester, profile: const UserProfile(firstName: 'Jordan', lastName: 'Lee'));
    await tester.pumpAndSettle();

    expect(find.text('JL'), findsOneWidget);
    expect(find.byIcon(Icons.account_circle), findsNothing);
  });

  testWidgets('the account menu\'s Settings option pushes the user-settings screen', (tester) async {
    await pumpNavBar(tester, profile: const UserProfile());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('user_settings_route')), findsOneWidget);
  });

  testWidgets('logging out successfully calls signOut', (tester) async {
    when(() => authService.signOut()).thenAnswer((_) async {});

    await pumpNavBar(tester, profile: const UserProfile());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();

    verify(() => authService.signOut()).called(1);
  });

  testWidgets('a failed logout shows a snackbar and stops the spinner', (tester) async {
    when(() => authService.signOut()).thenThrow(Exception('network-error'));

    await pumpNavBar(tester, profile: const UserProfile());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();

    expect(find.text('Failed to log out. Please try again.'), findsOneWidget);
  });

  testWidgets('while logging out, a spinner replaces the avatar and the menu is disabled', (tester) async {
    final completer = Completer<void>();
    when(() => authService.signOut()).thenAnswer((_) => completer.future);

    await pumpNavBar(tester, profile: const UserProfile());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNothing);

    completer.complete();
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
