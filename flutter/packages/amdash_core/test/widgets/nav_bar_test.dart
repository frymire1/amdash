import 'dart:async';

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

  // Mounted at '/nav-bar', not '/' — pumpApp's route table hardcodes '/'
  // to a keyed sentinel reserved for "navigation landed home" assertions
  // (see pumpAppHomeKey), so the widget under test needs its own path
  // whenever it needs real GoRouter plumbing (NavBar.context.push here).
  Future<void> pumpNavBar(WidgetTester tester, {UserProfile? profile}) {
    return pumpApp(
      tester,
      const SizedBox(),
      overrides: [
        authServiceProvider.overrideWithValue(authService),
        userProfileProvider.overrideWith((ref) => Stream.value(profile)),
      ],
      routes: {
        '/nav-bar': (_) => const Scaffold(appBar: NavBar()),
        '/user-settings': (_) => const Scaffold(body: Text('user-settings-placeholder')),
      },
      initialLocation: '/nav-bar',
    );
  }

  testWidgets('no profile / empty initials shows the fallback account icon', (tester) async {
    await pumpNavBar(tester);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.account_circle), findsOneWidget);
  });

  testWidgets('a profile with both names shows its initials', (tester) async {
    await pumpNavBar(tester, profile: const UserProfile(firstName: 'Jordan', lastName: 'Lee'));
    await tester.pumpAndSettle();

    expect(find.text('JL'), findsOneWidget);
    expect(find.byIcon(Icons.account_circle), findsNothing);
  });

  testWidgets('a profile missing a name still falls back to the icon (empty initials)', (tester) async {
    await pumpNavBar(tester, profile: const UserProfile(firstName: 'Jordan'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.account_circle), findsOneWidget);
  });

  testWidgets('tapping Settings pushes /user-settings', (tester) async {
    await pumpNavBar(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('user-settings-placeholder'), findsOneWidget);
  });

  testWidgets('tapping Logout calls signOut and shows a loading indicator meanwhile', (tester) async {
    // A Completer, not a plain `async {}` mock — deliberately controlled so
    // the "still loading" window isn't racing an instantly-resolving
    // Future against a single pump() (confirmed via the failing-signOut
    // test below that a synchronous-shaped throw never actually paints the
    // spinner at all: setState(true) and setState(false) both land before
    // the next frame, coalescing into one rebuild). Holding the Future
    // open here is what makes the loading state observable at all.
    final completer = Completer<void>();
    when(() => authService.signOut()).thenAnswer((_) => completer.future);

    await pumpNavBar(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    // Bounded pump()s, not pumpAndSettle(), from here on — PopupMenuButton
    // only invokes onSelected once its own closing transition finishes
    // (a few pumps' worth), and the instant _loggingOut flips true, its
    // indeterminate CircularProgressIndicator starts ticking forever,
    // which pumpAndSettle would never see settle while the completer
    // above is still unresolved.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete();
    await tester.pump();
    await tester.pump();

    verify(() => authService.signOut()).called(1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('signOut failing shows a snack bar and clears the loading state', (tester) async {
    when(() => authService.signOut()).thenThrow(Exception('network error'));

    await pumpNavBar(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();

    expect(find.text('Failed to log out. Please try again.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the popup menu is disabled while logging out', (tester) async {
    final completer = Completer<void>();
    when(() => authService.signOut()).thenAnswer((_) => completer.future);

    await pumpNavBar(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    // Bounded pumps through the popup's own closing transition — see the
    // identical comment in the loading-indicator test above.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final button = tester.widget<PopupMenuButton<String>>(find.byType(PopupMenuButton<String>));
    expect(button.enabled, false);

    completer.complete();
    await tester.pump();
    await tester.pump();
  });
}
