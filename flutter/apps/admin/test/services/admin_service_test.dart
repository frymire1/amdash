import 'package:admin/services/admin_service.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

class _MockHttpsCallable extends Mock implements HttpsCallable {}

class _MockHttpsCallableResult<T> extends Mock implements HttpsCallableResult<T> {}

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
  });

  group('setUserRole / removeUserRole', () {
    test('setUserRole sends email + the role\'s wire value', () async {
      final callable = stub('setUserRole', const <String, Object?>{});
      await service.setUserRole(email: 'a@b.com', role: UserRole.nurse);
      verify(() => callable.call<Map<Object?, Object?>>({'email': 'a@b.com', 'role': 'nurse'})).called(1);
    });

    test('removeUserRole sends email + the role\'s wire value', () async {
      final callable = stub('removeUserRole', const <String, Object?>{});
      await service.removeUserRole(email: 'a@b.com', role: UserRole.ems);
      verify(() => callable.call<Map<Object?, Object?>>({'email': 'a@b.com', 'role': 'ems'})).called(1);
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
  });

  group('deleteUser / setUserDisabled / resendInvite / resetUserMfa', () {
    test('deleteUser sends uid', () async {
      final callable = stub('deleteUser', const <String, Object?>{});
      await service.deleteUser('u1');
      verify(() => callable.call<Map<Object?, Object?>>({'uid': 'u1'})).called(1);
    });

    test('setUserDisabled sends uid + disabled', () async {
      final callable = stub('setUserDisabled', const <String, Object?>{});
      await service.setUserDisabled(uid: 'u1', disabled: true);
      verify(() => callable.call<Map<Object?, Object?>>({'uid': 'u1', 'disabled': true})).called(1);
    });

    test('resendInvite sends uid', () async {
      final callable = stub('resendInvite', const <String, Object?>{});
      await service.resendInvite('u1');
      verify(() => callable.call<Map<Object?, Object?>>({'uid': 'u1'})).called(1);
    });

    test('resetUserMfa sends uid', () async {
      final callable = stub('resetUserMfa', const <String, Object?>{});
      await service.resetUserMfa('u1');
      verify(() => callable.call<Map<Object?, Object?>>({'uid': 'u1'})).called(1);
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

    test('deleteHospital sends hospitalId', () async {
      final callable = stub('deleteHospital', const <String, Object?>{});
      await service.deleteHospital('h1');
      verify(() => callable.call<Map<Object?, Object?>>({'hospitalId': 'h1'})).called(1);
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
  });

  group('organization settings toggles', () {
    test('setOrganizationRetention sends retainAllData', () async {
      final callable = stub('setOrganizationRetention', const <String, Object?>{});
      await service.setOrganizationRetention(true);
      verify(() => callable.call<Map<Object?, Object?>>({'retainAllData': true})).called(1);
    });

    test('setOrganizationCountry sends country', () async {
      final callable = stub('setOrganizationCountry', const <String, Object?>{});
      await service.setOrganizationCountry('CA');
      verify(() => callable.call<Map<Object?, Object?>>({'country': 'CA'})).called(1);
    });

    test('setOrganizationCmekPreference sends cmekRequested', () async {
      final callable = stub('setOrganizationCmekPreference', const <String, Object?>{});
      await service.setOrganizationCmekPreference(true);
      verify(() => callable.call<Map<Object?, Object?>>({'cmekRequested': true})).called(1);
    });

    test('setOrganizationAuditLogging sends auditLoggingEnabled', () async {
      final callable = stub('setOrganizationAuditLogging', const <String, Object?>{});
      await service.setOrganizationAuditLogging(false);
      verify(() => callable.call<Map<Object?, Object?>>({'auditLoggingEnabled': false})).called(1);
    });

    test('setOrganizationFhirExportEnabled sends fhirExportEnabled', () async {
      final callable = stub('setOrganizationFhirExportEnabled', const <String, Object?>{});
      await service.setOrganizationFhirExportEnabled(true);
      verify(() => callable.call<Map<Object?, Object?>>({'fhirExportEnabled': true})).called(1);
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
