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

class _MockMultiFactorInfo extends Mock implements MultiFactorInfo {}

void main() {
  setUpAll(() {
    registerFallbackValue(_MockTotpSecret());
  });

  late _MockMfaService mfaService;
  late _MockAuthService authService;

  setUp(() {
    mfaService = _MockMfaService();
    authService = _MockAuthService();
    final user = _MockUser();
    when(() => user.email).thenReturn('jordan@example.com');
    when(() => authService.currentUser).thenReturn(user);
    // Every test's own body overrides mfaEnrolledFactorsProvider (it's
    // what selects which of the card's two top-line messages shows), so
    // this is just a safe default for tests that don't care about it.
  });

  Future<void> pumpCard(WidgetTester tester, {required List<MultiFactorInfo> factors}) {
    return pumpApp(
      tester,
      const MfaSecurityCard(),
      overrides: [
        mfaServiceProvider.overrideWithValue(mfaService),
        authServiceProvider.overrideWithValue(authService),
        mfaEnrolledFactorsProvider.overrideWith((ref) async => factors),
      ],
    );
  }

  _MockTotpSecret secretStub() {
    final secret = _MockTotpSecret();
    when(() => secret.secretKey).thenReturn('ABCD1234');
    when(
      () => secret.generateQrCodeUrl(accountName: any(named: 'accountName'), issuer: any(named: 'issuer')),
    ).thenAnswer((_) async => 'otpauth://totp/x');
    return secret;
  }

  testWidgets('enrolled: shows the "is on" message', (tester) async {
    await pumpCard(tester, factors: [_MockMultiFactorInfo()]);
    await tester.pumpAndSettle();

    expect(find.text('Two-step sign-in is on, using an authenticator app.'), findsOneWidget);
  });

  testWidgets('not enrolled: shows the "isn\'t set up yet" message', (tester) async {
    await pumpCard(tester, factors: []);
    await tester.pumpAndSettle();

    expect(find.text("Two-step sign-in isn't set up yet."), findsOneWidget);
  });

  testWidgets('loading: shows the checking message before the future resolves', (tester) async {
    await pumpApp(
      tester,
      const MfaSecurityCard(),
      overrides: [
        mfaServiceProvider.overrideWithValue(mfaService),
        authServiceProvider.overrideWithValue(authService),
        // Never completes -> still in the FutureProvider's loading state
        // after the first pump.
        mfaEnrolledFactorsProvider.overrideWith((ref) => Completer<List<MultiFactorInfo>>().future),
      ],
    );
    await tester.pump();

    expect(find.text('Checking your two-step sign-in status…'), findsOneWidget);
  });

  testWidgets('error: shows the load-failure message', (tester) async {
    await pumpApp(
      tester,
      const MfaSecurityCard(),
      overrides: [
        mfaServiceProvider.overrideWithValue(mfaService),
        authServiceProvider.overrideWithValue(authService),
        mfaEnrolledFactorsProvider.overrideWith((ref) async => throw Exception('firestore down')),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load your two-step sign-in status."), findsOneWidget);
  });

  testWidgets('cancelling the confirm dialog never calls unenrollTotp', (tester) async {
    await pumpCard(tester, factors: [_MockMultiFactorInfo()]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change authenticator app'));
    await tester.pumpAndSettle();
    expect(find.text('Change authenticator app?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    verifyNever(() => mfaService.unenrollTotp());
    expect(find.text('Change authenticator app'), findsOneWidget);
  });

  testWidgets('confirming starts the change flow and embeds TotpEnrollmentForm', (tester) async {
    when(() => mfaService.unenrollTotp()).thenAnswer((_) async {});
    when(() => mfaService.beginEnrollment()).thenAnswer((_) async => secretStub());

    await pumpCard(tester, factors: [_MockMultiFactorInfo()]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change authenticator app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Scan the new code, then confirm it below.'), findsOneWidget);
    expect(find.byType(TotpEnrollmentForm), findsOneWidget);
    verify(() => mfaService.unenrollTotp()).called(1);
  });

  testWidgets('TotpEnrollmentForm.onEnrolled collapses back to the normal (non-changing) view', (tester) async {
    when(() => mfaService.unenrollTotp()).thenAnswer((_) async {});
    when(() => mfaService.beginEnrollment()).thenAnswer((_) async => secretStub());
    when(() => mfaService.confirmEnrollment(any(), any())).thenAnswer((_) async {});

    await pumpCard(tester, factors: []);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change authenticator app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.byType(TotpEnrollmentForm), findsOneWidget);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(find.byType(TotpEnrollmentForm), findsNothing);
    expect(find.text('Change authenticator app'), findsOneWidget);
  });

  testWidgets('unenrollTotp failing (non-reauth) shows the generic remove-failure error', (tester) async {
    when(() => mfaService.unenrollTotp()).thenThrow(Exception('network error'));

    await pumpCard(tester, factors: [_MockMultiFactorInfo()]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change authenticator app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Could not remove your current authenticator. Please try again.'), findsOneWidget);
    // Stays on the non-changing view — never got as far as embedding the
    // enrollment form.
    expect(find.byType(TotpEnrollmentForm), findsNothing);
  });

  testWidgets('unenrollTotp requiring reauth prompts for password, then retries on success', (tester) async {
    var calls = 0;
    when(() => mfaService.unenrollTotp()).thenAnswer((_) async {
      calls++;
      if (calls == 1) throw const MfaRequiresRecentLoginException();
    });
    when(() => mfaService.reauthenticate(any())).thenAnswer((_) async {});
    when(() => mfaService.beginEnrollment()).thenAnswer((_) async => secretStub());

    await pumpCard(tester, factors: [_MockMultiFactorInfo()]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change authenticator app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    // Bounded pump()s, not pumpAndSettle() — _unenrollAndProceed() sets
    // _unenrolling: true right after this tap and keeps it true across the
    // whole await-the-reauth-dialog span (an indeterminate
    // CircularProgressIndicator underneath, still ticking behind the
    // dialog barrier), which never settles until the user actually answers
    // it further down — confirmed via a bisection probe that pumpAndSettle
    // hangs here specifically because of that ticker, the same
    // never-pumpAndSettle-across-an-indeterminate-spinner rule already
    // documented for status_pill.dart's own ticker.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    verify(() => mfaService.reauthenticate('hunter2')).called(1);
    expect(calls, 2);
    expect(find.byType(TotpEnrollmentForm), findsOneWidget);
  });

  testWidgets('cancelling the reauth prompt leaves the card on its non-changing/error-free state', (tester) async {
    when(
      () => mfaService.unenrollTotp(),
    ).thenAnswer((_) async => throw const MfaRequiresRecentLoginException());

    await pumpCard(tester, factors: [_MockMultiFactorInfo()]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change authenticator app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    // Bounded pump()s, not pumpAndSettle() — see the identical comment in
    // the test above; _unenrolling's indeterminate spinner is still
    // ticking underneath the reauth dialog barrier at this point.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    verifyNever(() => mfaService.reauthenticate(any()));
    expect(find.byType(TotpEnrollmentForm), findsNothing);
    expect(find.text('Change authenticator app'), findsOneWidget);
  });

  testWidgets('reauthenticate itself failing shows the reauth-specific error', (tester) async {
    when(
      () => mfaService.unenrollTotp(),
    ).thenAnswer((_) async => throw const MfaRequiresRecentLoginException());
    when(() => mfaService.reauthenticate(any())).thenThrow(Exception('wrong password'));

    await pumpCard(tester, factors: [_MockMultiFactorInfo()]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change authenticator app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    // Bounded pump()s, not pumpAndSettle() — see the identical comment in
    // the first reauth test above; _unenrolling's indeterminate spinner is
    // still ticking underneath the reauth dialog barrier at this point.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't verify your password. Please try again."), findsOneWidget);
  });
}
