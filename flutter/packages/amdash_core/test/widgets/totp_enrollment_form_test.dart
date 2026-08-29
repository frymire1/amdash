import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockMfaService extends Mock implements MfaService {}

class _MockAuthService extends Mock implements AuthService {}

class _MockUser extends Mock implements User {}

class _MockTotpSecret extends Mock implements TotpSecret {}

void main() {
  setUpAll(() {
    registerFallbackValue(_MockTotpSecret());
  });

  late _MockMfaService mfaService;
  late _MockAuthService authService;
  late _MockUser user;

  setUp(() {
    mfaService = _MockMfaService();
    authService = _MockAuthService();
    user = _MockUser();
    when(() => user.email).thenReturn('jordan@example.com');
    when(() => authService.currentUser).thenReturn(user);
  });

  Future<void> pumpForm(WidgetTester tester, {VoidCallback? onEnrolled}) {
    return pumpApp(
      tester,
      TotpEnrollmentForm(onEnrolled: onEnrolled ?? () {}),
      overrides: [
        mfaServiceProvider.overrideWithValue(mfaService),
        authServiceProvider.overrideWithValue(authService),
      ],
    );
  }

  _MockTotpSecret secretStub({String secretKey = 'ABCD1234', String qrUrl = 'otpauth://totp/x'}) {
    final secret = _MockTotpSecret();
    when(() => secret.secretKey).thenReturn(secretKey);
    when(
      () => secret.generateQrCodeUrl(accountName: any(named: 'accountName'), issuer: any(named: 'issuer')),
    ).thenAnswer((_) async => qrUrl);
    return secret;
  }

  testWidgets('shows the QR code + manual secret once beginEnrollment succeeds', (tester) async {
    when(() => mfaService.beginEnrollment()).thenAnswer((_) async => secretStub(secretKey: 'SECRET42'));

    await pumpForm(tester);
    await tester.pump();
    await tester.pump();

    expect(find.text('SECRET42'), findsOneWidget);
    expect(find.byKey(const Key('mfa_secret_key')), findsOneWidget);
  });

  testWidgets('beginEnrollment failing (non-reauth) shows the generic error + Try again', (tester) async {
    when(() => mfaService.beginEnrollment()).thenThrow(Exception('network error'));

    await pumpForm(tester);
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not start enrollment. Please try again.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('Try again retries beginEnrollment', (tester) async {
    var calls = 0;
    when(() => mfaService.beginEnrollment()).thenAnswer((_) async {
      calls++;
      if (calls == 1) throw Exception('boom');
      return secretStub();
    });

    await pumpForm(tester);
    await tester.pump();
    await tester.pump();
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();

    expect(calls, 2);
    expect(find.byKey(const Key('mfa_secret_key')), findsOneWidget);
  });

  testWidgets('beginEnrollment requiring reauth prompts for password, then retries on success', (tester) async {
    var calls = 0;
    when(() => mfaService.beginEnrollment()).thenAnswer((_) async {
      calls++;
      if (calls == 1) throw const MfaRequiresRecentLoginException();
      return secretStub();
    });
    when(() => mfaService.reauthenticate(any())).thenAnswer((_) async {});

    await pumpForm(tester);
    await tester.pump();
    await tester.pump();

    // showReauthPasswordDialog's own AlertDialog should now be showing.
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    verify(() => mfaService.reauthenticate('hunter2')).called(1);
    expect(calls, 2);
    expect(find.byKey(const Key('mfa_secret_key')), findsOneWidget);
  });

  testWidgets('cancelling the reauth prompt leaves the form on its error/try-again state', (tester) async {
    // thenAnswer(async => throw ...), not thenThrow — the real
    // beginEnrollment() is a Future-returning method that can never throw
    // synchronously (confirmed: MfaService._guardRecentLogin is itself
    // `async`), so it always rejects via a microtask, well after
    // initState()'s synchronous build-phase call stack has unwound. A bare
    // thenThrow makes the mock throw synchronously instead, which — since
    // _begin() is invoked directly (unawaited) from initState() — reaches
    // showReauthPasswordDialog's showDialog() call while the element is
    // still mid-mount, throwing "dependOnInheritedWidgetOfExactType...
    // called before initState() completed". That's a mocking-fidelity bug,
    // not reachable in production; matching the real async contract here
    // avoids it.
    when(() => mfaService.beginEnrollment()).thenAnswer((_) async => throw const MfaRequiresRecentLoginException());

    await pumpForm(tester);
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    verifyNever(() => mfaService.reauthenticate(any()));
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('reauthenticate itself failing shows the reauth-specific error', (tester) async {
    // thenAnswer(async => throw ...), not thenThrow — the real
    // beginEnrollment() is a Future-returning method that can never throw
    // synchronously (confirmed: MfaService._guardRecentLogin is itself
    // `async`), so it always rejects via a microtask, well after
    // initState()'s synchronous build-phase call stack has unwound. A bare
    // thenThrow makes the mock throw synchronously instead, which — since
    // _begin() is invoked directly (unawaited) from initState() — reaches
    // showReauthPasswordDialog's showDialog() call while the element is
    // still mid-mount, throwing "dependOnInheritedWidgetOfExactType...
    // called before initState() completed". That's a mocking-fidelity bug,
    // not reachable in production; matching the real async contract here
    // avoids it.
    when(() => mfaService.beginEnrollment()).thenAnswer((_) async => throw const MfaRequiresRecentLoginException());
    when(() => mfaService.reauthenticate(any())).thenThrow(Exception('wrong password'));

    await pumpForm(tester);
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't verify your password. Please try again."), findsOneWidget);
  });

  group('once the QR step is showing', () {
    setUp(() {
      when(() => mfaService.beginEnrollment()).thenAnswer((_) async => secretStub());
    });

    testWidgets('confirming with the right code calls onEnrolled and invalidates mfaEnrolledFactorsProvider', (
      tester,
    ) async {
      when(() => mfaService.confirmEnrollment(any(), any())).thenAnswer((_) async {});
      var enrolled = false;

      await pumpForm(tester, onEnrolled: () => enrolled = true);
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await tester.pump();

      verify(() => mfaService.confirmEnrollment(any(), '123456')).called(1);
      expect(enrolled, true);
    });

    testWidgets('submitting the code field via the keyboard (onSubmitted) also confirms', (tester) async {
      when(() => mfaService.confirmEnrollment(any(), any())).thenAnswer((_) async {});
      var enrolled = false;

      await pumpForm(tester, onEnrolled: () => enrolled = true);
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), '123456');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();

      verify(() => mfaService.confirmEnrollment(any(), '123456')).called(1);
      expect(enrolled, true);
    });

    testWidgets('shows a spinner while confirming is in flight', (tester) async {
      final completer = Completer<void>();
      when(() => mfaService.confirmEnrollment(any(), any())).thenAnswer((_) => completer.future);

      await pumpForm(tester);
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text('Confirm'));
      // Bounded pump, not pumpAndSettle() — same never-pumpAndSettle-
      // across-an-indeterminate-spinner rule as everywhere else this
      // session.
      await tester.pump();
      expect(find.text('Confirming…'), findsOneWidget);

      completer.complete();
      await tester.pumpAndSettle();
      expect(find.text('Confirming…'), findsNothing);
    });

    testWidgets('a wrong code shows the specific error message', (tester) async {
      when(() => mfaService.confirmEnrollment(any(), any())).thenThrow(Exception('invalid-verification-code'));

      await pumpForm(tester);
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), '000000');
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text("That code didn't work — double-check your authenticator app and try again."),
        findsOneWidget,
      );
    });

    testWidgets('confirmEnrollment requiring reauth prompts, then retries confirm on success', (tester) async {
      var calls = 0;
      when(() => mfaService.confirmEnrollment(any(), any())).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw const MfaRequiresRecentLoginException();
      });
      when(() => mfaService.reauthenticate(any())).thenAnswer((_) async {});
      var enrolled = false;

      await pumpForm(tester, onEnrolled: () => enrolled = true);
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'hunter2');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(calls, 2);
      expect(enrolled, true);
    });

    testWidgets('an empty code does nothing', (tester) async {
      await pumpForm(tester);
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Confirm'));
      await tester.pump();

      verifyNever(() => mfaService.confirmEnrollment(any(), any()));
    });

    testWidgets('"Generate a new code" resets back to the loading/QR step', (tester) async {
      await pumpForm(tester);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('mfa_secret_key')), findsOneWidget);

      await tester.tap(find.text('Generate a new code'));
      await tester.pump();
      await tester.pump();

      // beginEnrollment was called again (once at initState, once on reset).
      verify(() => mfaService.beginEnrollment()).called(2);
    });
  });
}
