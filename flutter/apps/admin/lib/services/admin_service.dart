import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/audit_log_entry.dart';
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

  Future<ManagedUser> updateUser({
    required String uid,
    String? email,
    String? firstName,
    String? lastName,
  }) async {
    final callable = _functions.httpsCallable('updateUser');
    final result = await callable.call<Map<Object?, Object?>>({
      'uid': uid,
      'email': ?email,
      'firstName': ?firstName,
      'lastName': ?lastName,
    });
    return ManagedUser.fromJson(result.data);
  }

  Future<void> deleteUser(String uid) {
    return _functions.httpsCallable('deleteUser').call<Map<Object?, Object?>>({'uid': uid});
  }

  Future<void> setUserDisabled({required String uid, required bool disabled}) {
    return _functions.httpsCallable('setUserDisabled').call<Map<Object?, Object?>>({
      'uid': uid,
      'disabled': disabled,
    });
  }

  Future<void> resendInvite(String uid) {
    return _functions.httpsCallable('resendInvite').call<Map<Object?, Object?>>({'uid': uid});
  }

  // The only real recovery path for a user locked out after losing their
  // authenticator device — see resetUserMfa's own doc comment in
  // functions/src/admin.ts for why self-service can't fix that case.
  Future<void> resetUserMfa(String uid) {
    return _functions.httpsCallable('resetUserMfa').call<Map<Object?, Object?>>({'uid': uid});
  }

  // Omit beforeTimestampMs for the first (most recent) page; pass the
  // previous page's oldest entry's timestamp to page further back.
  Future<AuditLogPage> listAuditLog({int? beforeTimestampMs}) async {
    final callable = _functions.httpsCallable('listAuditLog');
    final result = await callable.call<Map<Object?, Object?>>({'beforeTimestampMs': ?beforeTimestampMs});
    return AuditLogPage.fromJson(result.data);
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

  Future<Hospital> updateHospital({required String hospitalId, String? name, String? address}) async {
    final callable = _functions.httpsCallable('updateHospital');
    final result = await callable.call<Map<Object?, Object?>>({
      'hospitalId': hospitalId,
      'name': ?name,
      'address': ?address,
    });
    final data = result.data;
    return Hospital(
      id: data['id'] as String? ?? '',
      name: data['name'] as String? ?? '',
      address: data['address'] as String? ?? '',
      latitude: (data['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (data['longitude'] as num?)?.toDouble() ?? 0,
      // Not returned by updateHospital (see createHospital's identical gap
      // just above) — harmless here since no caller reads this field back;
      // hospitalsProvider's live Firestore stream is the real source of
      // truth for the table.
      organizationId: '',
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
    required String country,
  }) {
    return _functions.httpsCallable('createOrganization').call<Map<Object?, Object?>>({
      'organizationName': organizationName,
      'adminEmail': adminEmail,
      'adminFirstName': adminFirstName,
      'adminLastName': adminLastName,
      'country': country,
    });
  }

  Future<void> setOrganizationRetention(bool retainAllData) {
    return _functions.httpsCallable('setOrganizationRetention').call<Map<Object?, Object?>>({
      'retainAllData': retainAllData,
    });
  }

  Future<void> setOrganizationCountry(String country) {
    return _functions.httpsCallable('setOrganizationCountry').call<Map<Object?, Object?>>({
      'country': country,
    });
  }

  // Turns on real per-organization Cloud KMS envelope encryption for
  // patient.name/healthcareNumber (functions/src/kms.ts, functions/src/
  // patients.ts) — Firestore's own CMEK is whole-database and can only be
  // set at creation, so it can't be toggled per-org on this app's shared
  // database; this is the application-level equivalent.
  Future<void> setOrganizationCmekPreference(bool cmekRequested) {
    return _functions.httpsCallable('setOrganizationCmekPreference').call<Map<Object?, Object?>>({
      'cmekRequested': cmekRequested,
    });
  }

  // Gates only the patient-record actions (create/update/complete/delete/
  // decrypt) logged from functions/src/patients.ts — see audit.ts's
  // GATED_ACTIONS. Org/user/hospital management actions are always logged
  // regardless of this setting.
  Future<void> setOrganizationAuditLogging(bool auditLoggingEnabled) {
    return _functions.httpsCallable('setOrganizationAuditLogging').call<Map<Object?, Object?>>({
      'auditLoggingEnabled': auditLoggingEnabled,
    });
  }

  // Gates exportPatientFhirBundle (functions/src/patients.ts) — off by
  // default, opt-in only. The export callable re-checks this itself, so
  // this toggle is purely a capability switch, not the only enforcement.
  Future<void> setOrganizationFhirExportEnabled(bool fhirExportEnabled) {
    return _functions.httpsCallable('setOrganizationFhirExportEnabled').call<Map<Object?, Object?>>({
      'fhirExportEnabled': fhirExportEnabled,
    });
  }
}

final adminServiceProvider = Provider<AdminService>((ref) {
  return AdminService(FirebaseFunctions.instanceFor(region: _functionsRegion));
});
