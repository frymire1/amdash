import 'dart:async';

import 'package:admin/screens/user_settings_screen.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/pump_app.dart';

class _MockUser extends Mock implements User {}

class _MockAuthService extends Mock implements AuthService {}

class _MockUserProfileService extends Mock implements UserProfileService {}

class _MockMfaService extends Mock implements MfaService {}

void main() {
  late _MockUser user;
  late _MockAuthService authService;
  late _MockUserProfileService userProfileService;
  late _MockMfaService mfaService;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    user = _MockUser();
    when(() => user.uid).thenReturn('uid-1');
    when(() => user.email).thenReturn('jordan@example.com');
    authService = _MockAuthService();
    when(() => authService.currentUser).thenReturn(user);
    userProfileService = _MockUserProfileService();
    mfaService = _MockMfaService();
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    UserProfile profile = const UserProfile(firstName: 'Jordan', lastName: 'Lee'),
    List<MultiFactorInfo> mfaFactors = const [],
  }) {
    return pumpApp(
      tester,
      const UserSettingsScreen(),
      overrides: [
        authStateProvider.overrideWith((ref) => Stream.value(user)),
        userProfileProvider.overrideWith((ref) => Stream.value(profile)),
        userProfileServiceProvider.overrideWithValue(userProfileService),
        authServiceProvider.overrideWithValue(authService),
        mfaServiceProvider.overrideWithValue(mfaService),
        mfaEnrolledFactorsProvider.overrideWith((ref) async => mfaFactors),
      ],
      routes: {'/settings': (_) => const UserSettingsScreen()},
      initialLocation: '/settings',
    );
  }

  testWidgets('prefills the name fields from the live profile', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Jordan'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Lee'), findsOneWidget);
  });

  testWidgets('a blank profile leaves the fields empty', (tester) async {
    await pumpScreen(tester, profile: const UserProfile());
    await tester.pumpAndSettle();

    final firstNameField = tester.widget<TextField>(find.byType(TextField).first);
    expect(firstNameField.controller!.text, isEmpty);
  });

  testWidgets('tapping back with nothing to pop navigates home', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byKey(pumpAppHomeKey), findsOneWidget);
  });

  testWidgets('submitting with an empty name is a no-op', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Jordan'), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    verifyNever(() => userProfileService.saveProfile(any(), any(), any()));
  });

  testWidgets('saving successfully shows the success line', (tester) async {
    when(() => userProfileService.saveProfile(any(), any(), any())).thenAnswer((_) async {});

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Lee'), 'Nguyen');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    verify(() => userProfileService.saveProfile('uid-1', 'Jordan', 'Nguyen')).called(1);
    expect(find.text('Saved.'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('saving that times out shows the connection-specific message', (tester) async {
    when(() => userProfileService.saveProfile(any(), any(), any())).thenAnswer((_) => Completer<void>().future);

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    // Bounded pumps past the real 15s .timeout() — never pumpAndSettle()
    // while the Save button's own CircularProgressIndicator is ticking.
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    await tester.pump();

    expect(find.text('This is taking longer than expected. Check your connection and try again.'), findsOneWidget);
  });

  testWidgets('saving that fails generically shows the generic error', (tester) async {
    when(() => userProfileService.saveProfile(any(), any(), any())).thenThrow(Exception('permission-denied'));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Failed to save your details. Please try again.'), findsOneWidget);
  });

  testWidgets('no signed-in user renders nothing', (tester) async {
    await pumpApp(
      tester,
      const UserSettingsScreen(),
      overrides: [
        authStateProvider.overrideWith((ref) => Stream.value(null)),
        userProfileProvider.overrideWith((ref) => Stream.value(null)),
        userProfileServiceProvider.overrideWithValue(userProfileService),
        authServiceProvider.overrideWithValue(authService),
        mfaServiceProvider.overrideWithValue(mfaService),
        mfaEnrolledFactorsProvider.overrideWith((ref) async => const []),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('User Settings'), findsNothing);
  });

  testWidgets('the appearance control switches theme mode', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Dark'));
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.byType(UserSettingsScreen)));
    expect(container.read(themeModeProvider), ThemeMode.dark);
  });

  testWidgets('the embedded MfaSecurityCard reflects enrollment state', (tester) async {
    await pumpScreen(tester, mfaFactors: []);
    await tester.pumpAndSettle();

    expect(find.text("Two-step sign-in isn't set up yet."), findsOneWidget);
  });
}
