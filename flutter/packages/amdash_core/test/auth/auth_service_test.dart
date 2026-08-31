import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

class _MockHttpsCallable extends Mock implements HttpsCallable {}

class _MockHttpsCallableResult<T> extends Mock implements HttpsCallableResult<T> {}

class _MockFirebaseFirestore extends Mock implements FirebaseFirestore {}

void main() {
  setUpAll(() {
    registerFallbackValue(<String, Object?>{});
  });

  late _MockFirebaseFunctions functions;
  late _MockHttpsCallable callable;
  late _MockFirebaseFirestore firestore;
  late MockFirebaseAuth auth;

  setUp(() {
    functions = _MockFirebaseFunctions();
    callable = _MockHttpsCallable();
    firestore = _MockFirebaseFirestore();
    auth = MockFirebaseAuth();
    when(() => functions.httpsCallable(any())).thenReturn(callable);
    when(() => firestore.terminate()).thenAnswer((_) async {});
    when(() => firestore.clearPersistence()).thenAnswer((_) async {});
  });

  AuthService service() => AuthService(auth, functions, firestore);

  group('checkAccountStatus', () {
    test('calls the callable with the email and an empty allowedRoles by default, and parses the response', () async {
      final result = _MockHttpsCallableResult<Map<Object?, Object?>>();
      when(() => result.data).thenReturn({'exists': true, 'hasPassword': false});
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => result);

      final status = await service().checkAccountStatus('a@example.com');

      expect(status.exists, true);
      expect(status.hasPassword, false);
      verify(() => functions.httpsCallable('checkAccountStatus')).called(1);
      verify(() => callable.call<Map<Object?, Object?>>({'email': 'a@example.com', 'allowedRoles': <String>[]}))
          .called(1);
    });

    test('passes allowedRoles through as their wire values, and parses roleAllowed/role', () async {
      final result = _MockHttpsCallableResult<Map<Object?, Object?>>();
      when(() => result.data).thenReturn({
        'exists': true,
        'hasPassword': true,
        'roleAllowed': false,
        'role': ['physician'],
      });
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => result);

      final status = await service().checkAccountStatus(
        'a@example.com',
        allowedRoles: const [UserRole.ems],
      );

      expect(status.roleAllowed, false);
      expect(status.role, [UserRole.physician]);
      verify(
        () => callable.call<Map<Object?, Object?>>({
          'email': 'a@example.com',
          'allowedRoles': ['ems'],
        }),
      ).called(1);
    });
  });

  group('signIn', () {
    test('delegates to FirebaseAuth.signInWithEmailAndPassword', () async {
      final credential = await service().signIn('a@example.com', 'password123');
      expect(credential, isNotNull);
      expect(auth.currentUser, isNotNull);
    });
  });

  group('signOut', () {
    test('signs out of FirebaseAuth and clears local Firestore cache', () async {
      await auth.signInWithEmailAndPassword(email: 'a@example.com', password: 'password123');
      expect(auth.currentUser, isNotNull);

      await service().signOut();

      expect(auth.currentUser, isNull);
      verify(() => firestore.terminate()).called(1);
      verify(() => firestore.clearPersistence()).called(1);
    });

    test('swallows a failure clearing the local cache rather than throwing', () async {
      when(() => firestore.terminate()).thenThrow(Exception('already terminated'));

      // Should not throw despite terminate() failing — best-effort cleanup.
      await service().signOut();
      expect(auth.currentUser, isNull);
    });
  });

  group('resetPassword', () {
    test('calls the requestPasswordReset callable with the email', () async {
      final result = _MockHttpsCallableResult<Map<Object?, Object?>>();
      when(() => result.data).thenReturn(<Object?, Object?>{});
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => result);

      await service().resetPassword('a@example.com');

      verify(() => functions.httpsCallable('requestPasswordReset')).called(1);
      verify(() => callable.call<Map<Object?, Object?>>({'email': 'a@example.com'})).called(1);
    });
  });

  group('sendEmailVerification', () {
    test('calls the requestEmailVerification callable with no arguments', () async {
      final result = _MockHttpsCallableResult<Map<Object?, Object?>>();
      when(() => result.data).thenReturn(<Object?, Object?>{});
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => result);

      await service().sendEmailVerification();

      verify(() => functions.httpsCallable('requestEmailVerification')).called(1);
      verify(() => callable.call<Map<Object?, Object?>>(<String, Object?>{})).called(1);
    });
  });

  group('claimPasswordlessAccount', () {
    test('calls setInitialPassword then signs in with the new password', () async {
      final result = _MockHttpsCallableResult<Map<Object?, Object?>>();
      when(() => result.data).thenReturn(<Object?, Object?>{});
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => result);

      final credential = await service().claimPasswordlessAccount('a@example.com', 'newpassword123');

      verify(() => functions.httpsCallable('setInitialPassword')).called(1);
      verify(
        () => callable.call<Map<Object?, Object?>>({'email': 'a@example.com', 'password': 'newpassword123'}),
      ).called(1);
      expect(credential, isNotNull);
      expect(auth.currentUser, isNotNull);
    });
  });

  group('currentUser / isAuthenticated', () {
    test('reflects FirebaseAuth\'s own state', () async {
      expect(service().isAuthenticated, false);
      expect(service().currentUser, isNull);

      await auth.signInWithEmailAndPassword(email: 'a@example.com', password: 'password123');

      expect(service().isAuthenticated, true);
      expect(service().currentUser, isNotNull);
    });
  });

  group('authServiceProvider / authStateProvider', () {
    test('authServiceProvider is wired to the firebaseAuth/Functions/firestore seams', () {
      final container = ProviderContainer(
        overrides: [
          firebaseAuthProvider.overrideWithValue(auth),
          firebaseFunctionsProvider.overrideWithValue(functions),
          firestoreProvider.overrideWithValue(firestore),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(authServiceProvider), isA<AuthService>());
    });

    test('authStateProvider mirrors authServiceProvider\'s own authStateChanges stream', () async {
      final container = ProviderContainer(
        overrides: [
          firebaseAuthProvider.overrideWithValue(auth),
          firebaseFunctionsProvider.overrideWithValue(functions),
          firestoreProvider.overrideWithValue(firestore),
        ],
      );
      addTearDown(container.dispose);

      final initial = await container.read(authStateProvider.future);
      expect(initial, isNull);

      final credential = await auth.signInWithEmailAndPassword(email: 'a@example.com', password: 'password123');
      // authStateChanges() emits on sign-in — give the stream a moment to
      // deliver it, same reasoning as hospital_service_test.dart's own
      // "even Stream.value delivers via microtask" note.
      await Future<void>.delayed(Duration.zero);
      final signedIn = container.read(authStateProvider).valueOrNull;
      expect(signedIn?.uid, credential.user?.uid);
    });
  });
}
