import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/managed_user.dart';

/// Every callable Cloud Function this app hits runs in this region — must
/// match `REGION` in `functions/src/shared.ts`.
const _functionsRegion = 'northamerica-northeast2';

/// Mirrors `apps/admin/src/app/services/admin.service.ts`: thin wrappers
/// around the 8 admin-authored Cloud Functions (`functions/src/admin.ts`).
/// Every mutation here goes through a callable rather than a direct
/// Firestore write — `users`/`hospitals`/`organizations` are all
/// `allow write: if false` for clients (`firestore.rules`), so these
/// callables (Admin SDK, bypasses rules) are the only write path.
class AdminService {
  AdminService(this._functions);

  final FirebaseFunctions _functions;

  Future<ManagedUser> createUser({
    required String email,
    required String firstName,
    required String lastName,
    required UserRole role,
  }) async {
    final callable = _functions.httpsCallable('createUser');
    final result = await callable.call<Map<Object?, Object?>>({
      'email': email,
      'firstName': firstName,
      'lastName': lastName,
      'role': role.wireValue,
    });
    return ManagedUser.fromJson(result.data);
  }

  Future<void> setUserRole({required String email, required UserRole role}) {
    return _functions.httpsCallable('setUserRole').call<Map<Object?, Object?>>({
      'email': email,
      'role': role.wireValue,
    });
  }

  Future<void> removeUserRole({required String email, required UserRole role}) {
    return _functions.httpsCallable('removeUserRole').call<Map<Object?, Object?>>({
      'email': email,
      'role': role.wireValue,
    });
  }

  Future<List<ManagedUser>> listUsersWithRoles() async {
    final callable = _functions.httpsCallable('listUsersWithRoles');
    final result = await callable.call<List<Object?>>();
    return result.data
        .whereType<Map<Object?, Object?>>()
        .map(ManagedUser.fromJson)
        .toList();
  }

  Future<Hospital> createHospital({required String name, required String address}) async {
    final callable = _functions.httpsCallable('createHospital');
    final result = await callable.call<Map<Object?, Object?>>({'name': name, 'address': address});
    final data = result.data;
    return Hospital(
      id: data['id'] as String? ?? '',
      name: data['name'] as String? ?? '',
      address: data['address'] as String? ?? '',
      latitude: (data['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (data['longitude'] as num?)?.toDouble() ?? 0,
      organizationId: data['organizationId'] as String? ?? '',
    );
  }

  Future<void> deleteHospital(String hospitalId) {
    return _functions.httpsCallable('deleteHospital').call<Map<Object?, Object?>>({
      'hospitalId': hospitalId,
    });
  }

  Future<void> createOrganization({
    required String organizationName,
    required String adminEmail,
    required String adminFirstName,
    required String adminLastName,
  }) {
    return _functions.httpsCallable('createOrganization').call<Map<Object?, Object?>>({
      'organizationName': organizationName,
      'adminEmail': adminEmail,
      'adminFirstName': adminFirstName,
      'adminLastName': adminLastName,
    });
  }

  Future<void> setOrganizationRetention(bool retainAllData) {
    return _functions.httpsCallable('setOrganizationRetention').call<Map<Object?, Object?>>({
      'retainAllData': retainAllData,
    });
  }
}

final adminServiceProvider = Provider<AdminService>((ref) {
  return AdminService(FirebaseFunctions.instanceFor(region: _functionsRegion));
});
