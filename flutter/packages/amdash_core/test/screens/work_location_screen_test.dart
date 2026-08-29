import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockAuthService extends Mock implements AuthService {}

class _MockUser extends Mock implements User {}

class _MockUserProfileService extends Mock implements UserProfileService {}

const _hospitals = ['Ottawa General', 'Ottawa Civic', 'Kingston General'];

void main() {
  late _MockAuthService authService;
  late _MockUserProfileService userProfileService;

  setUp(() {
    authService = _MockAuthService();
    userProfileService = _MockUserProfileService();
    final user = _MockUser();
    when(() => user.uid).thenReturn('uid-1');
    when(() => authService.currentUser).thenReturn(user);
  });

  Future<void> pumpScreen(WidgetTester tester) {
    return pumpApp(
      tester,
      const SizedBox(),
      overrides: [
        authServiceProvider.overrideWithValue(authService),
        userProfileServiceProvider.overrideWithValue(userProfileService),
        hospitalNamesProvider.overrideWithValue(_hospitals),
      ],
      routes: {'/work-location': (_) => const WorkLocationScreen()},
      initialLocation: '/work-location',
    );
  }

  testWidgets('typing a name that matches no hospital and submitting shows the validation error', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Not A Real Hospital');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Select a hospital from the list.'), findsOneWidget);
    verifyNever(() => userProfileService.saveWorkLocation(any(), any()));
  });

  testWidgets('tapping outside the field marks it touched and shows the error for an unmatched value', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'partial');
    await tester.pump();
    // Tap a known on-screen widget outside the field's own bounds — a raw
    // tapAt(Offset(5, 5)) landed outside the app's actual hit-testable
    // content in this layout and never triggered onTapOutside at all.
    await tester.tap(find.text('Select Your Hospital'));
    await tester.pumpAndSettle();

    expect(find.text('Select a hospital from the list.'), findsOneWidget);
  });

  testWidgets('typing an exact hospital name and submitting saves it and navigates home', (tester) async {
    when(() => userProfileService.saveWorkLocation(any(), any())).thenAnswer((_) async {});

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Ottawa Civic');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    verify(() => userProfileService.saveWorkLocation('uid-1', 'Ottawa Civic')).called(1);
    expect(find.byKey(pumpAppHomeKey), findsOneWidget);
  });

  testWidgets('the autocomplete filters options by the typed query (case-insensitive substring)', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ottawa');
    await tester.pumpAndSettle();

    expect(find.text('Ottawa General'), findsOneWidget);
    expect(find.text('Ottawa Civic'), findsOneWidget);
    expect(find.text('Kingston General'), findsNothing);
  });

  testWidgets('selecting an option from the autocomplete list fills the field and allows submitting', (
    tester,
  ) async {
    when(() => userProfileService.saveWorkLocation(any(), any())).thenAnswer((_) async {});

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'kingston');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kingston General'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    verify(() => userProfileService.saveWorkLocation('uid-1', 'Kingston General')).called(1);
  });

  testWidgets('saveWorkLocation timing out shows the connection-specific message', (tester) async {
    // Never resolves — the real 15s .timeout() inside _submit is what
    // fires, not a manufactured TimeoutException from the mock, so this
    // exercises the actual timeout wiring rather than assuming its shape.
    when(() => userProfileService.saveWorkLocation(any(), any())).thenAnswer((_) => Completer<void>().future);

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Ottawa Civic');
    await tester.tap(find.text('Continue'));
    // Bounded pumps well past the 15s timeout, not pumpAndSettle() — the
    // indeterminate CircularProgressIndicator on the Continue button ticks
    // the whole time _submitting is true, same never-pumpAndSettle rule as
    // everywhere else this session.
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    await tester.pump();

    expect(find.text('This is taking longer than expected. Check your connection and try again.'), findsOneWidget);
  });

  testWidgets('saveWorkLocation failing generically shows the generic error', (tester) async {
    when(() => userProfileService.saveWorkLocation(any(), any())).thenThrow(Exception('permission-denied'));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Ottawa Civic');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Failed to save your work location. Please try again.'), findsOneWidget);
  });

  testWidgets('no signed-in user: matches a hospital but never calls saveWorkLocation or navigates', (
    tester,
  ) async {
    when(() => authService.currentUser).thenReturn(null);

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Ottawa Civic');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    verifyNever(() => userProfileService.saveWorkLocation(any(), any()));
    expect(find.byKey(pumpAppHomeKey), findsNothing);
    // Confirms the fix: the Continue button isn't stuck showing a
    // permanent spinner — _submitting was never set in the first place.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Continue'), findsOneWidget);
  });
}
