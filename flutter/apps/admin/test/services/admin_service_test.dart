import 'package:admin/services/admin_service.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

class _MockHttpsCallable extends Mock implements HttpsCallable {}

class _MockHttpsCallableResult<T> extends Mock implements HttpsCallableResult<T> {}

// FirebaseFunctionsException's real constructor is @protected (only
// callable from within its own package) and `code` is a plain inherited
// field from FirebaseException, not a mockable virtual member mocktail's
// when() can intercept cleanly — see amdash_core's login_screen_test.dart
// identical fake for the same workaround.
class _FakeFirebaseFunctionsException extends Fake implements FirebaseFunctionsException {
  _FakeFirebaseFunctionsException(this.code);

  @override
  final String code;
}

void main() {
  setUpAll(() {
    registerFallbackValue(<String, Object?>{});
  });

  late _MockFirebaseFunctions functions;
  late AdminService service;

  // Stubs `functions.httpsCallable(name)` to return a fresh mock callable
  // whose `.call<Map<Object?, Object?>>(...)` resolves to `data` — one line
  // per test instead of repeating the same 3-line setup for every one of
  // AdminService's 18 Map-returning callables. listUsersWithRoles is the
  // one exception (calls `.call<List<Object?>>()` instead) — see
  // stubList below.
  _MockHttpsCallable stub(String name, Map<Object?, Object?> data) {
    final callable = _MockHttpsCallable();
    final result = _MockHttpsCallableResult<Map<Object?, Object?>>();
    when(() => result.data).thenReturn(data);
    when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => result);
    when(() => functions.httpsCallable(name)).thenReturn(callable);
    return callable;
  }

  _MockHttpsCallable stubList(String name, List<Object?> data) {
    final callable = _MockHttpsCallable();
    final result = _MockHttpsCallableResult<List<Object?>>();
    when(() => result.data).thenReturn(data);
    when(() => callable.call<List<Object?>>()).thenAnswer((_) async => result);
    when(() => functions.httpsCallable(name)).thenReturn(callable);
    return callable;
  }

  // Exercises _callWithColdStartRetry's behavior for a given callable name
  // — shared by every "confirmed safe to retry" test below instead of each
  // repeating the same mock/call/verify block. The first call throws a
  // cold-start-shaped 'internal' failure; the second (the retry) succeeds
  // with `data`. Asserting exactly 2 calls is the real assertion — that
  // one retry actually happened, not zero and not more than one.
  Future<void> expectRetriesOnceOnInternal(
    String calleeName,
    Future<void> Function() invoke, {
    Map<Object?, Object?> data = const <String, Object?>{},
  }) async {
    final callable = _MockHttpsCallable();
    when(() => functions.httpsCallable(calleeName)).thenReturn(callable);
    final result = _MockHttpsCallableResult<Map<Object?, Object?>>();
    when(() => result.data).thenReturn(data);
    var calls = 0;
    when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async {
      calls++;
      if (calls == 1) throw _FakeFirebaseFunctionsException('internal');
      return result;
    });

    await invoke();

    expect(calls, 2);
  }

  // Same shape, for a callable this app deliberately does NOT retry
  // (createUser/createHospital/createOrganization — see
  // AdminService's own doc comment on why). Asserts the failure surfaces
  // immediately after exactly one call, not silently retried.
  Future<void> expectDoesNotRetry(String calleeName, Future<void> Function() invoke) async {
    final callable = _MockHttpsCallable();
    when(() => functions.httpsCallable(calleeName)).thenReturn(callable);
    var calls = 0;
    when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async {
      calls++;
      throw _FakeFirebaseFunctionsException('internal');
    });

    await expectLater(invoke(), throwsA(isA<FirebaseFunctionsException>()));
    expect(calls, 1);
  }

  setUp(() {
    functions = _MockFirebaseFunctions();
    service = AdminService(functions);
  });

  group('createUser', () {
    test('sends the role\'s wire value and parses the created user back', () async {
      final callable = stub('createUser', {'uid': 'u1', 'email': 'a@b.com', 'role': <String>[]});

      final user = await service.createUser(
        email: 'a@b.com',
        firstName: 'Jordan',
        lastName: 'Smith',
        role: UserRole.physician,
      );

      expect(user.uid, 'u1');
      verify(
        () => callable.call<Map<Object?, Object?>>({
          'email': 'a@b.com',
          'firstName': 'Jordan',
          'lastName': 'Smith',
          'role': 'physician',
        }),
      ).called(1);
    });

    test('is not retried on a cold-start "internal" failure — mints a new Auth uid every call', () async {
      await expectDoesNotRetry(
        'createUser',
        () => service.createUser(email: 'a@b.com', firstName: 'Jordan', lastName: 'Smith', role: UserRole.physician),
      );
    });
  });

  group('setUserRole / removeUserRole', () {
    test('setUserRole sends email + the role\'s wire value', () async {
      final callable = stub('setUserRole', const <String, Object?>{});
      await service.setUserRole(email: 'a@b.com', role: UserRole.nurse);
      verify(() => callable.call<Map<Object?, Object?>>({'email': 'a@b.com', 'role': 'nurse'})).called(1);
    });

    test('setUserRole retries once on a cold-start "internal" failure — arrayUnion is a no-op if reapplied', () async {
      await expectRetriesOnceOnInternal(
        'setUserRole',
        () => service.setUserRole(email: 'a@b.com', role: UserRole.nurse),
      );
    });

    test('removeUserRole sends email + the role\'s wire value', () async {
      final callable = stub('removeUserRole', const <String, Object?>{});
      await service.removeUserRole(email: 'a@b.com', role: UserRole.ems);
      verify(() => callable.call<Map<Object?, Object?>>({'email': 'a@b.com', 'role': 'ems'})).called(1);
    });

    test('removeUserRole retries once on a cold-start "internal" failure', () async {
      await expectRetriesOnceOnInternal(
        'removeUserRole',
        () => service.removeUserRole(email: 'a@b.com', role: UserRole.ems),
      );
    });
  });

  group('updateUser', () {
    test('omits null optional fields entirely, not as explicit nulls', () async {
      final callable = stub('updateUser', {'uid': 'u1'});
      await service.updateUser(uid: 'u1');
      verify(() => callable.call<Map<Object?, Object?>>({'uid': 'u1'})).called(1);
    });

    test('includes only the optional fields that were actually provided', () async {
      final callable = stub('updateUser', {'uid': 'u1', 'email': 'new@b.com'});
      final user = await service.updateUser(uid: 'u1', email: 'new@b.com');

      expect(user.uid, 'u1');
      verify(() => callable.call<Map<Object?, Object?>>({'uid': 'u1', 'email': 'new@b.com'})).called(1);
    });

    test('includes firstName/lastName too when they were provided', () async {
      final callable = stub('updateUser', {'uid': 'u1'});
      await service.updateUser(uid: 'u1', firstName: 'Jordan', lastName: 'Smith');

      verify(
        () => callable.call<Map<Object?, Object?>>({'uid': 'u1', 'firstName': 'Jordan', 'lastName': 'Smith'}),
      ).called(1);
    });

    test('retries once on a cold-start "internal" failure — setting the same fields twice is a no-op', () async {
      await expectRetriesOnceOnInternal(
        'updateUser',
        () => service.updateUser(uid: 'u1'),
        data: {'uid': 'u1'},
      );
    });
  });

  group('deleteUser / setUserDisabled / resendInvite / resetUserMfa', () {
    test('deleteUser sends uid', () async {
      final callable = stub('deleteUser', const <String, Object?>{});
      await service.deleteUser('u1');
      verify(() => callable.call<Map<Object?, Object?>>({'uid': 'u1'})).called(1);
    });

    test('deleteUser retries once on a cold-start "internal" failure, and succeeds', () async {
      final callable = _MockHttpsCallable();
      when(() => functions.httpsCallable('deleteUser')).thenReturn(callable);
      var calls = 0;
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw _FakeFirebaseFunctionsException('internal');
        return _MockHttpsCallableResult<Map<Object?, Object?>>();
      });

      await service.deleteUser('u1');

      expect(calls, 2);
    });

    test('deleteUser treats a not-found on the retry as success — the first attempt already worked', () async {
      final callable = _MockHttpsCallable();
      when(() => functions.httpsCallable('deleteUser')).thenReturn(callable);
      var calls = 0;
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async {
        calls++;
        throw _FakeFirebaseFunctionsException(calls == 1 ? 'internal' : 'not-found');
      });

      // Reaching here without throwing is the assertion.
      await service.deleteUser('u1');
      expect(calls, 2);
    });

    test('deleteUser does not retry a genuine error code (e.g. permission-denied)', () async {
      final callable = _MockHttpsCallable();
      when(() => functions.httpsCallable('deleteUser')).thenReturn(callable);
      var calls = 0;
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async {
        calls++;
        throw _FakeFirebaseFunctionsException('permission-denied');
      });

      await expectLater(service.deleteUser('u1'), throwsA(isA<FirebaseFunctionsException>()));
      expect(calls, 1);
    });

    test('deleteUser rethrows if the retry hits a real, different failure', () async {
      final callable = _MockHttpsCallable();
      when(() => functions.httpsCallable('deleteUser')).thenReturn(callable);
      var calls = 0;
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async {
        calls++;
        throw _FakeFirebaseFunctionsException(calls == 1 ? 'internal' : 'internal');
      });

      await expectLater(service.deleteUser('u1'), throwsA(isA<FirebaseFunctionsException>()));
      expect(calls, 2);
    });

    test('setUserDisabled sends uid + disabled', () async {
      final callable = stub('setUserDisabled', const <String, Object?>{});
      await service.setUserDisabled(uid: 'u1', disabled: true);
      verify(() => callable.call<Map<Object?, Object?>>({'uid': 'u1', 'disabled': true})).called(1);
    });

    test('setUserDisabled retries once on a cold-start "internal" failure', () async {
      await expectRetriesOnceOnInternal(
        'setUserDisabled',
        () => service.setUserDisabled(uid: 'u1', disabled: true),
      );
    });

    test('resendInvite sends uid', () async {
      final callable = stub('resendInvite', const <String, Object?>{});
      await service.resendInvite('u1');
      verify(() => callable.call<Map<Object?, Object?>>({'uid': 'u1'})).called(1);
    });

    test('resendInvite retries once on a cold-start "internal" failure', () async {
      await expectRetriesOnceOnInternal('resendInvite', () => service.resendInvite('u1'));
    });

    test('resetUserMfa sends uid', () async {
      final callable = stub('resetUserMfa', const <String, Object?>{});
      await service.resetUserMfa('u1');
      verify(() => callable.call<Map<Object?, Object?>>({'uid': 'u1'})).called(1);
    });

    test('resetUserMfa retries once on a cold-start "internal" failure', () async {
      await expectRetriesOnceOnInternal('resetUserMfa', () => service.resetUserMfa('u1'));
    });
  });

  group('listAuditLog', () {
    test('omits beforeTimestampMs for the first page', () async {
      final callable = stub('listAuditLog', {
        'entries': [
          {'id': 'log-1', 'action': 'user.create'},
        ],
        'hasMore': true,
      });

      final page = await service.listAuditLog();

      expect(page.entries, hasLength(1));
      expect(page.hasMore, true);
      verify(() => callable.call<Map<Object?, Object?>>(const <String, Object?>{})).called(1);
    });

    test('passes beforeTimestampMs to page further back', () async {
      final callable = stub('listAuditLog', {'entries': <Object?>[], 'hasMore': false});
      await service.listAuditLog(beforeTimestampMs: 1700000000000);
      verify(() => callable.call<Map<Object?, Object?>>({'beforeTimestampMs': 1700000000000})).called(1);
    });

    test('retries once on a cold-start "internal" failure — a pure read', () async {
      await expectRetriesOnceOnInternal(
        'listAuditLog',
        () => service.listAuditLog(),
        data: {'entries': <Object?>[], 'hasMore': false},
      );
    });
  });

  group('listUsersWithRoles', () {
    test('calls the callable with no arguments and maps every result entry', () async {
      final callable = stubList('listUsersWithRoles', [
        {'uid': 'u1', 'email': 'a@b.com'},
        {'uid': 'u2', 'email': 'c@d.com'},
      ]);

      final users = await service.listUsersWithRoles();

      expect(users, hasLength(2));
      expect(users[0].uid, 'u1');
      expect(users[1].uid, 'u2');
      verify(() => callable.call<List<Object?>>()).called(1);
    });

    test('non-Map entries in the response are skipped', () async {
      stubList('listUsersWithRoles', [
        {'uid': 'u1'},
        'not a map',
      ]);

      final users = await service.listUsersWithRoles();
      expect(users, hasLength(1));
    });

    test('retries once on a cold-start "internal" failure — a pure read', () async {
      final callable = _MockHttpsCallable();
      when(() => functions.httpsCallable('listUsersWithRoles')).thenReturn(callable);
      final result = _MockHttpsCallableResult<List<Object?>>();
      when(() => result.data).thenReturn(<Object?>[]);
      var calls = 0;
      when(() => callable.call<List<Object?>>()).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw _FakeFirebaseFunctionsException('internal');
        return result;
      });

      await service.listUsersWithRoles();

      expect(calls, 2);
    });
  });

  group('createHospital / updateHospital / deleteHospital', () {
    test('createHospital sends name+address and parses the created hospital, coercing lat/lng to double', () async {
      final callable = stub('createHospital', {
        'id': 'h1',
        'name': 'General',
        'address': '123 Main St',
        'latitude': 45,
        'longitude': -75,
        'organizationId': 'org-1',
      });

      final hospital = await service.createHospital(name: 'General', address: '123 Main St');

      expect(hospital.id, 'h1');
      expect(hospital.latitude, 45.0);
      expect(hospital.longitude, -75.0);
      expect(hospital.organizationId, 'org-1');
      verify(
        () => callable.call<Map<Object?, Object?>>({'name': 'General', 'address': '123 Main St'}),
      ).called(1);
    });

    test('createHospital defaults missing numeric/string fields rather than throwing', () async {
      stub('createHospital', const <String, Object?>{});
      final hospital = await service.createHospital(name: 'General', address: '123 Main St');

      expect(hospital.id, '');
      expect(hospital.latitude, 0);
      expect(hospital.longitude, 0);
    });

    test('createHospital is not retried on a cold-start "internal" failure — .add() mints a new doc ID every call', () async {
      await expectDoesNotRetry(
        'createHospital',
        () => service.createHospital(name: 'General', address: '123 Main St'),
      );
    });

    test('updateHospital omits null optional fields and always reports an empty organizationId '
        '(not returned by the callable)', () async {
      final callable = stub('updateHospital', {'id': 'h1', 'name': 'Renamed'});

      final hospital = await service.updateHospital(hospitalId: 'h1', name: 'Renamed');

      expect(hospital.name, 'Renamed');
      expect(hospital.organizationId, '');
      verify(() => callable.call<Map<Object?, Object?>>({'hospitalId': 'h1', 'name': 'Renamed'})).called(1);
    });

    test('updateHospital includes address too when it was provided', () async {
      final callable = stub('updateHospital', {'id': 'h1', 'address': '456 Elm St'});
      await service.updateHospital(hospitalId: 'h1', address: '456 Elm St');

      verify(
        () => callable.call<Map<Object?, Object?>>({'hospitalId': 'h1', 'address': '456 Elm St'}),
      ).called(1);
    });

    test('updateHospital retries once on a cold-start "internal" failure', () async {
      await expectRetriesOnceOnInternal(
        'updateHospital',
        () => service.updateHospital(hospitalId: 'h1', name: 'Renamed'),
        data: {'id': 'h1', 'name': 'Renamed'},
      );
    });

    test('deleteHospital sends hospitalId', () async {
      final callable = stub('deleteHospital', const <String, Object?>{});
      await service.deleteHospital('h1');
      verify(() => callable.call<Map<Object?, Object?>>({'hospitalId': 'h1'})).called(1);
    });

    test('deleteHospital retries once on a cold-start "internal" failure, and succeeds', () async {
      await expectRetriesOnceOnInternal('deleteHospital', () => service.deleteHospital('h1'));
    });

    test('deleteHospital treats a not-found on the retry as success — the first attempt already worked', () async {
      final callable = _MockHttpsCallable();
      when(() => functions.httpsCallable('deleteHospital')).thenReturn(callable);
      var calls = 0;
      when(() => callable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async {
        calls++;
        throw _FakeFirebaseFunctionsException(calls == 1 ? 'internal' : 'not-found');
      });

      // Reaching here without throwing is the assertion.
      await service.deleteHospital('h1');
      expect(calls, 2);
    });
  });

  group('createOrganization', () {
    test('sends every field the org-creation form collects', () async {
      final callable = stub('createOrganization', const <String, Object?>{});

      await service.createOrganization(
        organizationName: 'Acme EMS',
        adminEmail: 'admin@acme.com',
        adminFirstName: 'Jordan',
        adminLastName: 'Smith',
        country: 'CA',
      );

      verify(
        () => callable.call<Map<Object?, Object?>>({
          'organizationName': 'Acme EMS',
          'adminEmail': 'admin@acme.com',
          'adminFirstName': 'Jordan',
          'adminLastName': 'Smith',
          'country': 'CA',
        }),
      ).called(1);
    });

    test('is not retried on a cold-start "internal" failure — chains a new Auth account + org doc every call', () async {
      await expectDoesNotRetry(
        'createOrganization',
        () => service.createOrganization(
          organizationName: 'Acme EMS',
          adminEmail: 'admin@acme.com',
          adminFirstName: 'Jordan',
          adminLastName: 'Smith',
          country: 'CA',
        ),
      );
    });
  });

  group('organization settings toggles', () {
    test('setOrganizationRetention sends retainAllData', () async {
      final callable = stub('setOrganizationRetention', const <String, Object?>{});
      await service.setOrganizationRetention(true);
      verify(() => callable.call<Map<Object?, Object?>>({'retainAllData': true})).called(1);
    });

    test('setOrganizationRetention retries once on a cold-start "internal" failure', () async {
      await expectRetriesOnceOnInternal('setOrganizationRetention', () => service.setOrganizationRetention(true));
    });

    test('setOrganizationCountry sends country', () async {
      final callable = stub('setOrganizationCountry', const <String, Object?>{});
      await service.setOrganizationCountry('CA');
      verify(() => callable.call<Map<Object?, Object?>>({'country': 'CA'})).called(1);
    });

    test('setOrganizationCountry retries once on a cold-start "internal" failure', () async {
      await expectRetriesOnceOnInternal('setOrganizationCountry', () => service.setOrganizationCountry('CA'));
    });

    test('setOrganizationCmekPreference sends cmekRequested', () async {
      final callable = stub('setOrganizationCmekPreference', const <String, Object?>{});
      await service.setOrganizationCmekPreference(true);
      verify(() => callable.call<Map<Object?, Object?>>({'cmekRequested': true})).called(1);
    });

    test('setOrganizationCmekPreference retries once on a cold-start "internal" failure — reuses the existing key',
        () async {
      await expectRetriesOnceOnInternal(
        'setOrganizationCmekPreference',
        () => service.setOrganizationCmekPreference(true),
      );
    });

    test('setOrganizationAuditLogging sends auditLoggingEnabled', () async {
      final callable = stub('setOrganizationAuditLogging', const <String, Object?>{});
      await service.setOrganizationAuditLogging(false);
      verify(() => callable.call<Map<Object?, Object?>>({'auditLoggingEnabled': false})).called(1);
    });

    test('setOrganizationAuditLogging retries once on a cold-start "internal" failure', () async {
      await expectRetriesOnceOnInternal(
        'setOrganizationAuditLogging',
        () => service.setOrganizationAuditLogging(false),
      );
    });

    test('setOrganizationFhirExportEnabled sends fhirExportEnabled', () async {
      final callable = stub('setOrganizationFhirExportEnabled', const <String, Object?>{});
      await service.setOrganizationFhirExportEnabled(true);
      verify(() => callable.call<Map<Object?, Object?>>({'fhirExportEnabled': true})).called(1);
    });

    test('setOrganizationFhirExportEnabled retries once on a cold-start "internal" failure', () async {
      await expectRetriesOnceOnInternal(
        'setOrganizationFhirExportEnabled',
        () => service.setOrganizationFhirExportEnabled(true),
      );
    });
  });

  group('adminServiceProvider', () {
    test('is wired to firebaseFunctionsProvider\'s current instance', () {
      final container = ProviderContainer(overrides: [firebaseFunctionsProvider.overrideWithValue(functions)]);
      addTearDown(container.dispose);

      expect(container.read(adminServiceProvider), isA<AdminService>());
    });
  });
}
