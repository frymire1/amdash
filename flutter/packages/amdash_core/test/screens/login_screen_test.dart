import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/pump_app.dart';

class _MockAuthService extends Mock implements AuthService {}

class _MockUser extends Mock implements User {}

class _MockMultiFactorResolver extends Mock implements MultiFactorResolver {}

class _MockMultiFactorInfo extends Mock implements MultiFactorInfo {}

class _MockFirebaseAuthException extends Mock implements FirebaseAuthException {}

class _MockFirebaseAuthMultiFactorException extends Mock implements FirebaseAuthMultiFactorException {}

// See TESTING.md's MockPlatformInterfaceMixin note — same technique
// access_denied_screen_test.dart already uses for the exact same reason:
// url_launcher's own UrlLauncherPlatform extends PlatformInterface too.
class _MockUrlLauncherPlatform extends Mock with MockPlatformInterfaceMixin implements UrlLauncherPlatform {}

// A Fake, not a Mock — its real (`@protected`) constructor can't be called
// from outside the package, and `code` is a plain inherited field (from
// FirebaseException), not a mockable virtual member mocktail's `when()` can
// intercept cleanly. Fake + a constructor-set override sidesteps both.
class _FakeFirebaseFunctionsException extends Fake implements FirebaseFunctionsException {
  _FakeFirebaseFunctionsException(this.code);

  @override
  final String code;
}

// Shared by every "rate-limited" test below — mirrors exactly what the
// cloud_functions client SDK surfaces when the server throws
// HttpsError('resource-exhausted', ...) (see functions/src/rate-limit.ts).
FirebaseFunctionsException _rateLimitException() => _FakeFirebaseFunctionsException('resource-exhausted');

void main() {
  setUpAll(() {
    // LaunchOptions: url_launcher's own second launchUrl() argument, same
    // registration access_denied_screen_test.dart already needs for the
    // identical reason. List<UserRole>: needed for
    // `any(named: 'allowedRoles')` below, since checkAccountStatus's real
    // signature takes one there.
    registerFallbackValue(const LaunchOptions());
    registerFallbackValue(<UserRole>[]);
  });

  late _MockAuthService authService;
  late _MockUrlLauncherPlatform urlLauncher;
  late UrlLauncherPlatform realUrlLauncher;

  setUp(() {
    authService = _MockAuthService();
    urlLauncher = _MockUrlLauncherPlatform();
    realUrlLauncher = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = urlLauncher;
    when(() => urlLauncher.launchUrl(any(), any())).thenAnswer((_) async => true);
  });

  tearDown(() => UrlLauncherPlatform.instance = realUrlLauncher);

  Future<void> pumpScreen(WidgetTester tester, {Stream<User?>? authState}) {
    return pumpApp(
      tester,
      const LoginScreen(appName: 'AmDash — Test', allowedRoles: [UserRole.ems]),
      overrides: [
        authServiceProvider.overrideWithValue(authService),
        authStateProvider.overrideWith((ref) => authState ?? Stream.value(null)),
      ],
    );
  }

  Future<void> goToEmailStep(WidgetTester tester) async {
    await pumpScreen(tester);
    // authStateProvider's first Stream.value(null) emission lands via a
    // microtask, not synchronously with pumpWidget's first frame — without
    // this, the widget is still showing the auth-state guard's loading
    // spinner (not the email form) when callers immediately try to
    // interact with a TextField.
    await tester.pumpAndSettle();
  }

  Future<void> submitEmail(WidgetTester tester, String email) async {
    await tester.enterText(find.byType(TextField).first, email);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  group('auth-state guard', () {
    testWidgets('still loading shows a spinner, not the form', (tester) async {
      await pumpScreen(tester, authState: const Stream.empty());
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Sign in to continue'), findsNothing);
    });

    testWidgets('already signed in shows a spinner, not the form (redirect imminent)', (tester) async {
      await pumpScreen(tester, authState: Stream.value(_MockUser()));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Sign in to continue'), findsNothing);
    });

    testWidgets('resolved and signed out shows the email-step form', (tester) async {
      await goToEmailStep(tester);
      await tester.pumpAndSettle();

      expect(find.text('Sign in to continue'), findsOneWidget);
    });
  });

  group('email step', () {
    testWidgets('an empty email does nothing', (tester) async {
      await goToEmailStep(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue'));
      await tester.pump();

      verifyNever(() => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')));
    });

    testWidgets('a malformed email shows a validation error and never calls checkAccountStatus', (tester) async {
      await goToEmailStep(tester);
      await submitEmail(tester, 'not-an-email');

      expect(find.text('Enter a valid email address.'), findsOneWidget);
      verifyNever(() => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')));
    });

    testWidgets('submitting via the keyboard (onSubmitted) works the same as tapping Continue', (tester) async {
      when(
        () => authService.checkAccountStatus('jordan@example.com', allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer((_) async => const AccountStatus(exists: true, hasPassword: true, roleAllowed: true, role: []));

      await goToEmailStep(tester);
      await tester.enterText(find.byType(TextField).first, 'jordan@example.com');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      verify(
        () => authService.checkAccountStatus('jordan@example.com', allowedRoles: any(named: 'allowedRoles')),
      ).called(1);
    });

    testWidgets('passes the screen\'s own allowedRoles through to checkAccountStatus', (tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer((_) async => const AccountStatus(exists: true, hasPassword: true, roleAllowed: true, role: []));

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');

      verify(
        () => authService.checkAccountStatus('jordan@example.com', allowedRoles: const [UserRole.ems]),
      ).called(1);
    });

    testWidgets('a non-existent account shows the not-activated step with the email interpolated', (tester) async {
      when(
        () => authService.checkAccountStatus('nobody@example.com', allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer((_) async => const AccountStatus(exists: false, hasPassword: false, roleAllowed: false, role: []));

      await goToEmailStep(tester);
      await submitEmail(tester, 'nobody@example.com');

      expect(find.text('Account not activated'), findsOneWidget);
      expect(find.textContaining('nobody@example.com'), findsOneWidget);

      await tester.tap(find.text('Use a different email'));
      await tester.pumpAndSettle();
      expect(find.text('Sign in to continue'), findsOneWidget);
    });

    testWidgets('checkAccountStatus failing shows the generic error, stays on the email step', (tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenThrow(Exception('network error'));

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');

      expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
      expect(find.text('Sign in to continue'), findsOneWidget);
    });

    testWidgets('checkAccountStatus rate-limited shows a friendly rate-limit message, not the generic one', (
      tester,
    ) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenThrow(_rateLimitException());

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');

      expect(find.text("You've tried too many times. Please wait a while before trying again."), findsOneWidget);
      expect(find.text('Something went wrong. Please try again.'), findsNothing);
    });

    testWidgets('exists without a password goes to the set-password step', (tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer((_) async => const AccountStatus(exists: true, hasPassword: false, roleAllowed: true, role: []));

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');

      expect(find.text("Your admin team has set up your account, now just create a password."), findsOneWidget);
    });

    testWidgets('exists with a password goes to the sign-in step', (tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer((_) async => const AccountStatus(exists: true, hasPassword: true, roleAllowed: true, role: []));

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');

      expect(find.text('Sign in as jordan@example.com'), findsOneWidget);
    });
  });

  group('wrong-app step', () {
    // The whole point of this feature: caught right after email, before
    // ever reaching set-password/sign-in/MFA — not just eventually, via
    // AppRouteGuard's own role tier post-auth (see LoginScreen's own doc
    // comment).
    testWidgets('roleAllowed: false goes straight to the wrong-app step, not set-password or sign-in', (
      tester,
    ) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer(
        (_) async =>
            const AccountStatus(exists: true, hasPassword: false, roleAllowed: false, role: [UserRole.physician]),
      );

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');

      expect(find.text('Access denied'), findsOneWidget);
      expect(find.textContaining("doesn't have access to the AmDash — Test app"), findsOneWidget);
      expect(find.text("Your admin team has set up your account, now just create a password."), findsNothing);
      expect(find.text('Sign in as jordan@example.com'), findsNothing);
    });

    testWidgets('offers a link for each of the account\'s real roles, and none for roles it lacks', (tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer(
        (_) async => const AccountStatus(exists: true, hasPassword: true, roleAllowed: false, role: [UserRole.ems]),
      );

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');

      expect(find.text('Try one of your other apps:'), findsOneWidget);
      expect(find.text('EMS app'), findsOneWidget);
      expect(find.text('Physician app'), findsNothing);
      expect(find.text('Admin app'), findsNothing);
    });

    testWidgets('no matching role at all hides the "other apps" section entirely', (tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer((_) async => const AccountStatus(exists: true, hasPassword: true, roleAllowed: false, role: []));

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');

      expect(find.text('Try one of your other apps:'), findsNothing);
    });

    testWidgets('tapping the EMS app button launches its real URL', (tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer(
        (_) async => const AccountStatus(exists: true, hasPassword: true, roleAllowed: false, role: [UserRole.ems]),
      );

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');

      await tester.tap(find.text('EMS app'));
      await tester.pump();

      verify(() => urlLauncher.launchUrl(AppUrls.ems, any())).called(1);
    });

    testWidgets('tapping the Physician app button launches its real URL', (tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer(
        (_) async => const AccountStatus(
          exists: true,
          hasPassword: true,
          roleAllowed: false,
          role: [UserRole.physician],
        ),
      );

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');

      await tester.tap(find.text('Physician app'));
      await tester.pump();

      verify(() => urlLauncher.launchUrl(AppUrls.physician, any())).called(1);
    });

    testWidgets('tapping the Admin app button launches its real URL', (tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer(
        (_) async => const AccountStatus(
          exists: true,
          hasPassword: true,
          roleAllowed: false,
          role: [UserRole.superAdmin],
        ),
      );

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');

      await tester.tap(find.text('Admin app'));
      await tester.pump();

      verify(() => urlLauncher.launchUrl(AppUrls.admin, any())).called(1);
    });

    testWidgets('Use a different email returns to the email step and drops the offered links', (tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer(
        (_) async => const AccountStatus(exists: true, hasPassword: true, roleAllowed: false, role: [UserRole.ems]),
      );

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');
      expect(find.text('EMS app'), findsOneWidget);

      await tester.tap(find.text('Use a different email'));
      await tester.pumpAndSettle();

      expect(find.text('Sign in to continue'), findsOneWidget);
      expect(find.text('EMS app'), findsNothing);
    });
  });

  group('set-password step', () {
    Future<void> goToSetPassword(WidgetTester tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer((_) async => const AccountStatus(exists: true, hasPassword: false, roleAllowed: true, role: []));
      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');
    }

    testWidgets('a weak password shows exactly its missing requirement bullets', (tester) async {
      await goToSetPassword(tester);

      // 8+ chars, has a number, has a special char, but no uppercase.
      await tester.enterText(find.byType(TextField).first, 'abcdefg1!');
      await tester.pump();

      expect(find.text('•  One uppercase letter'), findsOneWidget);
      expect(find.text('•  At least 8 characters'), findsNothing);
      expect(find.text('•  One number'), findsNothing);
      expect(find.text('•  One special character'), findsNothing);
    });

    testWidgets('a fully-strong password hides every hint bullet', (tester) async {
      await goToSetPassword(tester);

      await tester.enterText(find.byType(TextField).first, 'Abcdefg1!');
      await tester.pump();

      expect(find.textContaining('•'), findsNothing);
    });

    testWidgets('the password and confirm-password fields each have their own visibility toggle', (tester) async {
      await goToSetPassword(tester);

      TextField passwordField() => tester.widget<TextField>(find.byType(TextField).first);
      TextField confirmField() => tester.widget<TextField>(find.byType(TextField).last);
      expect(passwordField().obscureText, true);
      expect(confirmField().obscureText, true);

      await tester.tap(find.byIcon(Icons.visibility_off).first);
      await tester.pump();
      expect(passwordField().obscureText, false);
      expect(confirmField().obscureText, true);

      await tester.tap(find.byIcon(Icons.visibility_off).first);
      await tester.pump();
      expect(confirmField().obscureText, false);
    });

    testWidgets('submitting the confirm-password field via the keyboard also submits', (tester) async {
      when(() => authService.claimPasswordlessAccount(any(), any())).thenAnswer((_) async => _FakeUserCredential());

      await goToSetPassword(tester);
      await tester.enterText(find.byType(TextField).first, 'Abcdefg1!');
      await tester.enterText(find.byType(TextField).last, 'Abcdefg1!');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      verify(() => authService.claimPasswordlessAccount('jordan@example.com', 'Abcdefg1!')).called(1);
    });

    testWidgets('mismatched confirm shows the mismatch message; matching shows the match message', (tester) async {
      await goToSetPassword(tester);

      await tester.enterText(find.byType(TextField).first, 'Abcdefg1!');
      await tester.enterText(find.byType(TextField).last, 'different');
      await tester.pump();
      expect(find.text('Passwords do not match'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'Abcdefg1!');
      await tester.pump();
      expect(find.text('Passwords match!'), findsOneWidget);
    });

    testWidgets('Set Password is disabled until every requirement is met', (tester) async {
      await goToSetPassword(tester);

      await tester.enterText(find.byType(TextField).first, 'weak');
      await tester.pump();
      final disabledButton = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(disabledButton.onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, 'Abcdefg1!');
      await tester.enterText(find.byType(TextField).last, 'Abcdefg1!');
      await tester.pump();
      final enabledButton = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(enabledButton.onPressed, isNotNull);
    });

    testWidgets('submitting calls claimPasswordlessAccount with the email and new password', (tester) async {
      when(() => authService.claimPasswordlessAccount(any(), any())).thenAnswer((_) async => _FakeUserCredential());

      await goToSetPassword(tester);
      await tester.enterText(find.byType(TextField).first, 'Abcdefg1!');
      await tester.enterText(find.byType(TextField).last, 'Abcdefg1!');
      await tester.pump();
      await tester.tap(find.text('Set Password'));
      await tester.pumpAndSettle();

      verify(() => authService.claimPasswordlessAccount('jordan@example.com', 'Abcdefg1!')).called(1);
    });

    testWidgets('claimPasswordlessAccount failing shows the generic set-password error', (tester) async {
      when(() => authService.claimPasswordlessAccount(any(), any())).thenThrow(Exception('weak-password'));

      await goToSetPassword(tester);
      await tester.enterText(find.byType(TextField).first, 'Abcdefg1!');
      await tester.enterText(find.byType(TextField).last, 'Abcdefg1!');
      await tester.pump();
      await tester.tap(find.text('Set Password'));
      await tester.pumpAndSettle();

      expect(find.text('Could not set your password. Please try again.'), findsOneWidget);
    });

    testWidgets('claimPasswordlessAccount rate-limited shows a friendly rate-limit message', (tester) async {
      when(() => authService.claimPasswordlessAccount(any(), any())).thenThrow(_rateLimitException());

      await goToSetPassword(tester);
      await tester.enterText(find.byType(TextField).first, 'Abcdefg1!');
      await tester.enterText(find.byType(TextField).last, 'Abcdefg1!');
      await tester.pump();
      await tester.tap(find.text('Set Password'));
      await tester.pumpAndSettle();

      expect(find.text("You've tried too many times. Please wait a while before trying again."), findsOneWidget);
    });

    testWidgets('Use a different email clears the password fields and returns to the email step', (tester) async {
      await goToSetPassword(tester);
      await tester.enterText(find.byType(TextField).first, 'Abcdefg1!');
      await tester.pump();

      await tester.tap(find.text('Use a different email'));
      await tester.pumpAndSettle();

      expect(find.text('Sign in to continue'), findsOneWidget);
      // The email itself carries over (so the user can just edit it), but a
      // fresh visit to set-password would start from an empty password.
      expect(find.text('jordan@example.com'), findsOneWidget);
    });
  });

  group('sign-in step', () {
    Future<void> goToSignIn(WidgetTester tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer((_) async => const AccountStatus(exists: true, hasPassword: true, roleAllowed: true, role: []));
      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');
    }

    testWidgets('submitting calls signIn with the email and password', (tester) async {
      when(() => authService.signIn(any(), any())).thenAnswer((_) async => _FakeUserCredential());

      await goToSignIn(tester);
      await tester.enterText(find.byType(TextField).first, 'hunter2');
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      verify(() => authService.signIn('jordan@example.com', 'hunter2')).called(1);
    });

    testWidgets('the password visibility toggle switches obscureText', (tester) async {
      await goToSignIn(tester);

      TextField passwordField() => tester.widget<TextField>(find.byType(TextField).first);
      expect(passwordField().obscureText, true);

      await tester.tap(find.byIcon(Icons.visibility_off));
      await tester.pump();
      expect(passwordField().obscureText, false);
    });

    testWidgets('submitting via the keyboard also signs in', (tester) async {
      when(() => authService.signIn(any(), any())).thenAnswer((_) async => _FakeUserCredential());

      await goToSignIn(tester);
      await tester.enterText(find.byType(TextField).first, 'hunter2');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      verify(() => authService.signIn('jordan@example.com', 'hunter2')).called(1);
    });

    testWidgets('a FirebaseAuthException shows the invalid-credentials message', (tester) async {
      when(() => authService.signIn(any(), any())).thenThrow(_MockFirebaseAuthException());

      await goToSignIn(tester);
      await tester.enterText(find.byType(TextField).first, 'wrong');
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      expect(find.text('Invalid email or password.'), findsOneWidget);
    });

    testWidgets('a generic failure shows the generic error', (tester) async {
      when(() => authService.signIn(any(), any())).thenThrow(Exception('network error'));

      await goToSignIn(tester);
      await tester.enterText(find.byType(TextField).first, 'hunter2');
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
    });

    testWidgets('a FirebaseAuthMultiFactorException moves to the MFA-challenge step', (tester) async {
      final hint = _MockMultiFactorInfo();
      when(() => hint.factorId).thenReturn('totp');
      when(() => hint.uid).thenReturn('factor-1');
      final resolver = _MockMultiFactorResolver();
      when(() => resolver.hints).thenReturn([hint]);
      final mfaException = _MockFirebaseAuthMultiFactorException();
      when(() => mfaException.resolver).thenReturn(resolver);
      when(() => authService.signIn(any(), any())).thenThrow(mfaException);

      await goToSignIn(tester);
      await tester.enterText(find.byType(TextField).first, 'hunter2');
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      expect(find.text('Enter the 6-digit code from your authenticator app'), findsOneWidget);
    });

    testWidgets('forgot password succeeding shows the sent confirmation', (tester) async {
      final completer = Completer<void>();
      when(() => authService.resetPassword(any())).thenAnswer((_) => completer.future);

      await goToSignIn(tester);
      await tester.tap(find.text('Forgot password?'));
      // Bounded pumps, not pumpAndSettle — the button's own label swap to
      // "Sending…" is observed deterministically via the held-open
      // completer, same technique as nav_bar_test.dart's logout spinner.
      await tester.pump();
      expect(find.text('Sending…'), findsOneWidget);

      completer.complete();
      await tester.pumpAndSettle();

      verify(() => authService.resetPassword('jordan@example.com')).called(1);
      expect(find.text('Password reset email sent — check your inbox.'), findsOneWidget);
    });

    testWidgets('forgot password failing shows the reset-failure message', (tester) async {
      when(() => authService.resetPassword(any())).thenThrow(Exception('user-not-found'));

      await goToSignIn(tester);
      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();

      expect(find.text('Could not send a reset email for that address.'), findsOneWidget);
    });

    testWidgets('forgot password rate-limited shows a friendly rate-limit message', (tester) async {
      when(() => authService.resetPassword(any())).thenThrow(_rateLimitException());

      await goToSignIn(tester);
      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();

      expect(find.text("You've tried too many times. Please wait a while before trying again."), findsOneWidget);
    });

    testWidgets('Use a different email clears the password field and returns to the email step', (tester) async {
      await goToSignIn(tester);
      await tester.enterText(find.byType(TextField).first, 'hunter2');

      await tester.tap(find.text('Use a different email'));
      await tester.pumpAndSettle();

      expect(find.text('Sign in to continue'), findsOneWidget);
    });
  });

  group('MFA-challenge step', () {
    Future<void> goToMfaChallenge(WidgetTester tester) async {
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer((_) async => const AccountStatus(exists: true, hasPassword: true, roleAllowed: true, role: []));
      final hint = _MockMultiFactorInfo();
      when(() => hint.factorId).thenReturn('totp');
      when(() => hint.uid).thenReturn('factor-1');
      final resolver = _MockMultiFactorResolver();
      when(() => resolver.hints).thenReturn([hint]);
      final mfaException = _MockFirebaseAuthMultiFactorException();
      when(() => mfaException.resolver).thenReturn(resolver);
      when(() => authService.signIn(any(), any())).thenThrow(mfaException);

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');
      await tester.enterText(find.byType(TextField).first, 'hunter2');
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();
    }

    testWidgets('an empty code does nothing', (tester) async {
      await goToMfaChallenge(tester);

      await tester.tap(find.text('Verify'));
      await tester.pump();

      // Still on the challenge step, no error surfaced.
      expect(find.text('Enter the 6-digit code from your authenticator app'), findsOneWidget);
    });

    testWidgets('Use a different email clears the code field and returns to the email step', (tester) async {
      await goToMfaChallenge(tester);
      await tester.enterText(find.byType(TextField).first, '123456');

      await tester.tap(find.text('Use a different email'));
      await tester.pumpAndSettle();

      expect(find.text('Sign in to continue'), findsOneWidget);
    });

    testWidgets('submitting a code reaches the real TOTP assertion call, which never resolves in-test', (
      tester,
    ) async {
      // TotpMultiFactorGenerator.getAssertionForSignIn is a real platform-
      // channel SDK static — confirmed via bisection (bounded pumps well
      // past this await, watching _submitting) that unlike
      // mfa_service.dart's generateSecret/getAssertionForEnrollment (which
      // at least throw immediately), this one just hangs forever in a
      // plain Dart VM test, so its own success/failure handling is
      // unreachable (see the coverage:ignore block in login_screen.dart).
      // Only the reachable part is testable: the tap enters the
      // _submitting state and the call gets made at all. No pumpAndSettle
      // here — it would never settle, same never-pumpAndSettle-across-an-
      // indeterminate-spinner rule as everywhere else this session, except
      // here the spinner never clears at all rather than just taking a
      // moment to.
      await goToMfaChallenge(tester);

      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.tap(find.text('Verify'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Verifying…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('submitting the code via the keyboard also reaches _submitMfaChallenge', (tester) async {
      // Same never-resolves-in-test call as above — this just confirms the
      // onSubmitted wiring itself (not the Verify button) also reaches it.
      await goToMfaChallenge(tester);

      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();

      expect(find.text('Verifying…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no totp hint on the resolver shows the generic error and resets _submitting', (tester) async {
      // resolver.hints.firstWhere((h) => h.factorId == 'totp') throws a
      // synchronous StateError when nothing matches — reachable and
      // testable even though the ignored getAssertionForSignIn call below
      // it never is (see the previous test): this is exactly what
      // _submitMfaChallenge's generic catch/finally are for.
      when(
        () => authService.checkAccountStatus(any(), allowedRoles: any(named: 'allowedRoles')),
      ).thenAnswer((_) async => const AccountStatus(exists: true, hasPassword: true, roleAllowed: true, role: []));
      final resolver = _MockMultiFactorResolver();
      when(() => resolver.hints).thenReturn(const []);
      final mfaException = _MockFirebaseAuthMultiFactorException();
      when(() => mfaException.resolver).thenReturn(resolver);
      when(() => authService.signIn(any(), any())).thenThrow(mfaException);

      await goToEmailStep(tester);
      await submitEmail(tester, 'jordan@example.com');
      await tester.enterText(find.byType(TextField).first, 'hunter2');
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.tap(find.text('Verify'));
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
      // _submitting was reset by the finally block, not left stuck true.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Verify'), findsOneWidget);
    });
  });
}

class _FakeUserCredential extends Fake implements UserCredential {}
