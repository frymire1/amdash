// Phase 0/1 verification: runs against real Chrome (via
// `flutter drive --driver=test_driver/integration_test.dart -d chrome`)
// and drives the actual widget tree — not a canvas-pixel scrape — proving
// real Firebase Auth + Firestore connectivity against amdash-dev. The
// throwaway account this signs in with is created directly via the
// Firebase Admin SDK (same pattern used by every e2e suite's own
// support/admin.ts in the Angular apps) and is not created by this test —
// pass its email/password via --dart-define.
import 'package:ems/firebase_options.dart';
import 'package:ems/main.dart';
import 'package:ems/screens/home_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('signs in against a real amdash-dev account and reaches home', (tester) async {
    const email = String.fromEnvironment('SMOKE_EMAIL');
    const password = String.fromEnvironment('SMOKE_PASSWORD');
    expect(email, isNotEmpty, reason: 'pass --dart-define=SMOKE_EMAIL=...');
    expect(password, isNotEmpty, reason: 'pass --dart-define=SMOKE_PASSWORD=...');

    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    await tester.pumpWidget(const ProviderScope(child: EmsApp()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, email);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(find.text('Sign In'), findsOneWidget, reason: 'should have reached the sign-in step');

    await tester.enterText(find.byType(TextField).first, password);
    await tester.tap(find.text('Sign In'));
    await tester.pumpAndSettle(const Duration(seconds: 8));

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('EMS Dashboard'), findsOneWidget);
    expect(FirebaseAuth.instance.currentUser?.email, email);
  });
}
