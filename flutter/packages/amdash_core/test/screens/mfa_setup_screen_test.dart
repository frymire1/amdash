import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockAuthService extends Mock implements AuthService {}

class _MockUser extends Mock implements User {}

class _MockMfaService extends Mock implements MfaService {}

class _MockTotpSecret extends Mock implements TotpSecret {}

void main() {
  setUpAll(() {
    registerFallbackValue(_MockTotpSecret());
  });

  late _MockAuthService authService;
  late _MockMfaService mfaService;
  late _MockUser user;

  setUp(() {
    authService = _MockAuthService();
    mfaService = _MockMfaService();
    user = _MockUser();
    when(() => user.email).thenReturn('jordan@example.com');
    when(() => authService.currentUser).thenReturn(user);
  });

  Future<void> pumpScreen(WidgetTester tester) {
    return pumpApp(
      tester,
      const SizedBox(),
      overrides: [
        authServiceProvider.overrideWithValue(authService),
        mfaServiceProvider.overrideWithValue(mfaService),
      ],
      routes: {'/mfa-setup': (_) => const MfaSetupScreen()},
      initialLocation: '/mfa-setup',
    );
  }

  group('email not yet verified', () {
    setUp(() {
      when(() => user.emailVerified).thenReturn(false);
    });

    testWidgets('shows the verify-email step with the account email interpolated', (tester) async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('Verify your email'), findsOneWidget);
      expect(find.textContaining('jordan@example.com'), findsOneWidget);
    });

    testWidgets('Resend succeeding shows the sent confirmation', (tester) async {
      when(() => authService.sendEmailVerification()).thenAnswer((_) async {});

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Resend verification email'));
      await tester.pumpAndSettle();

      expect(find.text('Verification email sent — check your inbox.'), findsOneWidget);
    });

    testWidgets('Resend shows a spinner while in flight', (tester) async {
      final completer = Completer<void>();
      when(() => authService.sendEmailVerification()).thenAnswer((_) => completer.future);

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Resend verification email'));
      // Bounded pump, not pumpAndSettle() — the indeterminate spinner ticks
      // for as long as the completer's unresolved, same never-
      // pumpAndSettle-across-an-indeterminate-spinner rule as everywhere
      // else this session.
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      completer.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('Resend failing shows the generic send-failure message', (tester) async {
      when(() => authService.sendEmailVerification()).thenThrow(Exception('network error'));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Resend verification email'));
      await tester.pumpAndSettle();

      expect(find.text('Could not send a verification email. Please try again.'), findsOneWidget);
    });

    testWidgets("checking verification while still unverified shows the still-not-verified message", (
      tester,
    ) async {
      when(() => user.reload()).thenAnswer((_) async {});

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text("I've verified — continue"));
      await tester.pumpAndSettle();

      expect(find.text('Still not verified — check your inbox (and spam folder) for the link.'), findsOneWidget);
      expect(find.text('Verify your email'), findsOneWidget);
    });

    testWidgets("checking verification shows a spinner while in flight", (tester) async {
      final completer = Completer<void>();
      when(() => user.reload()).thenAnswer((_) => completer.future);

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text("I've verified — continue"));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Checking…'), findsOneWidget);

      completer.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('checking verification failing shows the generic check-failure message', (tester) async {
      when(() => user.reload()).thenThrow(Exception('network error'));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text("I've verified — continue"));
      await tester.pumpAndSettle();

      expect(find.text('Could not check verification status. Please try again.'), findsOneWidget);
    });

    testWidgets('checking verification and it now being verified switches to the enroll step', (tester) async {
      // reload() itself flips the mock's own emailVerified stub — models
      // the real SDK's reload() refreshing currentUser's cached fields
      // in place, which _isEmailVerified re-reads on the next build.
      when(() => user.reload()).thenAnswer((_) async {
        when(() => user.emailVerified).thenReturn(true);
      });
      when(() => mfaService.beginEnrollment()).thenAnswer((_) async => Completer<TotpSecret>().future);

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text("I've verified — continue"));
      await tester.pumpAndSettle();

      expect(find.text('Set up your authenticator app'), findsOneWidget);
      expect(find.byType(TotpEnrollmentForm), findsOneWidget);
    });
  });

  group('email already verified', () {
    setUp(() {
      when(() => user.emailVerified).thenReturn(true);
    });

    testWidgets('goes straight to the enroll step, embedding TotpEnrollmentForm', (tester) async {
      when(() => mfaService.beginEnrollment()).thenAnswer((_) async => Completer<TotpSecret>().future);

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('Set up your authenticator app'), findsOneWidget);
      expect(find.byType(TotpEnrollmentForm), findsOneWidget);
    });

    testWidgets('a completed enrollment navigates home', (tester) async {
      final secret = _MockTotpSecret();
      when(() => secret.secretKey).thenReturn('ABCD1234');
      when(
        () => secret.generateQrCodeUrl(accountName: any(named: 'accountName'), issuer: any(named: 'issuer')),
      ).thenAnswer((_) async => 'otpauth://totp/x');
      when(() => mfaService.beginEnrollment()).thenAnswer((_) async => secret);
      when(() => mfaService.confirmEnrollment(any(), any())).thenAnswer((_) async {});

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '123456');
      // The QR code pushes Confirm below the 600px test-viewport fold
      // inside the screen's own SingleChildScrollView — scroll it into
      // view first, or the tap misses entirely.
      await tester.ensureVisible(find.text('Confirm'));
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.byKey(pumpAppHomeKey), findsOneWidget);
    });
  });
}
