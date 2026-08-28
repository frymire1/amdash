import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockFirebaseAuth extends Mock implements FirebaseAuth {}

class _MockUser extends Mock implements User {}

// firebase_auth_mocks' own MockUser doesn't implement `.multiFactor` at all
// (confirmed for real — calling it throws NoSuchMethodError), so this file
// uses raw mocktail mocks for FirebaseAuth/User/MultiFactor instead, for
// full control over the MFA-specific surface.
class _MockMultiFactor extends Mock implements MultiFactor {}

class _MockMultiFactorInfo extends Mock implements MultiFactorInfo {}

class _MockUserCredential extends Mock implements UserCredential {}

class _FakeAuthCredential extends Fake implements AuthCredential {}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeAuthCredential());
  });

  late _MockFirebaseAuth auth;
  late _MockUser user;
  late _MockMultiFactor multiFactor;

  setUp(() {
    auth = _MockFirebaseAuth();
    user = _MockUser();
    multiFactor = _MockMultiFactor();
    when(() => user.multiFactor).thenReturn(multiFactor);
  });

  MfaService service() => MfaService(auth);

  group('reauthenticate', () {
    test('reauthenticates with an email/password credential built from the current user', () async {
      when(() => auth.currentUser).thenReturn(user);
      when(() => user.email).thenReturn('a@example.com');
      final credential = _MockUserCredential();
      when(() => user.reauthenticateWithCredential(any())).thenAnswer((_) async => credential);

      await service().reauthenticate('password123');

      final captured = verify(() => user.reauthenticateWithCredential(captureAny())).captured;
      final usedCredential = captured.single as EmailAuthCredential;
      expect(usedCredential.email, 'a@example.com');
    });

    test('throws when there is no signed-in user', () async {
      when(() => auth.currentUser).thenReturn(null);
      expect(() => service().reauthenticate('password123'), throwsStateError);
    });

    test('throws when the signed-in user has no email', () async {
      when(() => auth.currentUser).thenReturn(user);
      when(() => user.email).thenReturn(null);
      expect(() => service().reauthenticate('password123'), throwsStateError);
    });
  });

  group('beginEnrollment / confirmEnrollment — no signed-in user', () {
    test('beginEnrollment throws without reaching the TOTP SDK call', () async {
      when(() => auth.currentUser).thenReturn(null);
      expect(() => service().beginEnrollment(), throwsStateError);
    });

    test('confirmEnrollment throws without reaching the TOTP SDK call', () async {
      when(() => auth.currentUser).thenReturn(null);
      expect(
        () => service().confirmEnrollment(_FakeTotpSecret(), '123456'),
        throwsStateError,
      );
    });
  });

  group('unenrollTotp', () {
    test('throws when there is no signed-in user', () async {
      when(() => auth.currentUser).thenReturn(null);
      expect(() => service().unenrollTotp(), throwsStateError);
    });

    test('unenrolls only the totp-factorId entries, leaving others alone', () async {
      when(() => auth.currentUser).thenReturn(user);
      final totpFactor = _MockMultiFactorInfo();
      when(() => totpFactor.factorId).thenReturn('totp');
      final phoneFactor = _MockMultiFactorInfo();
      when(() => phoneFactor.factorId).thenReturn('phone');
      when(() => multiFactor.getEnrolledFactors()).thenAnswer((_) async => [totpFactor, phoneFactor]);
      when(() => multiFactor.unenroll(multiFactorInfo: any(named: 'multiFactorInfo'))).thenAnswer((_) async {});

      await service().unenrollTotp();

      verify(() => multiFactor.unenroll(multiFactorInfo: totpFactor)).called(1);
      verifyNever(() => multiFactor.unenroll(multiFactorInfo: phoneFactor));
    });

    test('does nothing when no factors are enrolled', () async {
      when(() => auth.currentUser).thenReturn(user);
      when(() => multiFactor.getEnrolledFactors()).thenAnswer((_) async => []);

      await service().unenrollTotp();

      verifyNever(() => multiFactor.unenroll(multiFactorInfo: any(named: 'multiFactorInfo')));
    });
  });

  group('_guardRecentLogin error translation (exercised via unenrollTotp)', () {
    test('translates a "requires-recent-login"-flavored error into MfaRequiresRecentLoginException', () async {
      when(() => auth.currentUser).thenReturn(user);
      when(() => multiFactor.getEnrolledFactors()).thenThrow(
        FirebaseAuthException(code: 'requires-recent-login', message: 'stale session'),
      );

      await expectLater(
        service().unenrollTotp(),
        throwsA(isA<MfaRequiresRecentLoginException>()),
      );
    });

    test('translates the REST API\'s CREDENTIAL_TOO_OLD_LOGIN_AGAIN error too, case-insensitively', () async {
      when(() => auth.currentUser).thenReturn(user);
      when(() => multiFactor.getEnrolledFactors()).thenThrow(
        Exception('CREDENTIAL_TOO_OLD_LOGIN_AGAIN'),
      );

      await expectLater(
        service().unenrollTotp(),
        throwsA(isA<MfaRequiresRecentLoginException>()),
      );
    });

    test('rethrows an unrelated error as-is, not translated', () async {
      when(() => auth.currentUser).thenReturn(user);
      when(() => multiFactor.getEnrolledFactors()).thenThrow(Exception('network-request-failed'));

      await expectLater(
        service().unenrollTotp(),
        throwsA(
          isA<Exception>().having((e) => e.toString(), 'message', contains('network-request-failed')),
        ),
      );
    });
  });

  group('mfaServiceProvider', () {
    test('is wired to firebaseAuthProvider\'s current instance', () {
      final container = ProviderContainer(
        overrides: [firebaseAuthProvider.overrideWithValue(auth)],
      );
      addTearDown(container.dispose);

      expect(container.read(mfaServiceProvider), isA<MfaService>());
    });
  });

  group('mfaEnrolledFactorsProvider', () {
    // Same settling race as hospital_service_test.dart's own containerFor
    // helper — awaiting authStateProvider.future first (before ever
    // reading mfaEnrolledFactorsProvider) avoids it, rather than risking a
    // rebuild-mid-flight hang.
    test('is empty when signed out (authStateProvider yields null)', () async {
      final container = ProviderContainer(
        overrides: [authStateProvider.overrideWith((ref) => Stream.value(null))],
      );
      addTearDown(container.dispose);
      await container.read(authStateProvider.future);

      final factors = await container.read(mfaEnrolledFactorsProvider.future);
      expect(factors, isEmpty);
    });

    test('fetches the signed-in user\'s own enrolled factors', () async {
      final totpFactor = _MockMultiFactorInfo();
      when(() => multiFactor.getEnrolledFactors()).thenAnswer((_) async => [totpFactor]);

      final container = ProviderContainer(
        overrides: [authStateProvider.overrideWith((ref) => Stream.value(user))],
      );
      addTearDown(container.dispose);
      await container.read(authStateProvider.future);

      final factors = await container.read(mfaEnrolledFactorsProvider.future);
      expect(factors, [totpFactor]);
    });
  });
}

// A minimal stand-in — confirmEnrollment's own "no signed-in user" branch
// throws before this value is ever actually read.
class _FakeTotpSecret implements TotpSecret {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
