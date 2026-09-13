import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/audit_log_entry.dart';
import '../classes/managed_user.dart';

/// Mirrors `apps/admin/src/app/services/admin.service.ts`: thin wrappers
/// around the 8 admin-authored Cloud Functions (`functions/src/admin.ts`).
/// Every mutation here goes through a callable rather than a direct
/// Firestore write — `users`/`hospitals`/`organizations` are all
/// `allow write: if false` for clients (`firestore.rules`), so these
/// callables (Admin SDK, bypasses rules) are the only write path.
class AdminService {
  AdminService(this._functions);

  final FirebaseFunctions _functions;

  // Cloud Functions v2 (Cloud Run under the hood) can drop the very first
  // request after scaling up from zero — confirmed for real via a genuine
  // admin-app failure on deleteUser (browser console:
  // net::ERR_CONNECTION_CLOSED; Cloud Run's own logs showing a fresh
  // instance starting right beforehand) that reached the Flutter SDK as
  // FirebaseFunctionsException(code: 'internal'). This isn't really a
  // cold-start-speed problem — Google's own load-balancer troubleshooting
  // docs describe the actual mechanism directly: "the backend closes the
  // idle connection, but the load balancer does not know and sends a
  // request on the dead connection" — a keep-alive race that can happen
  // any time a backend instance is being created or torn down, on any
  // load-balanced HTTP service, not something specific to this function or
  // even to Google Cloud. It's why browsers themselves silently retry GET
  // requests that fail this way; a POST isn't auto-retried by the browser
  // since it isn't inherently safe to repeat.
  //
  // Applied only to callables confirmed genuinely idempotent — converging
  // an EXISTING, already-identified resource to a target state, so calling
  // them twice in a row has the exact same end result as calling them
  // once: role add/remove (Firestore arrayUnion/arrayRemove — a no-op if
  // already applied), field updates (setting the same value twice is a
  // no-op; Admin SDK's email-uniqueness check only fires against a
  // *different* account, not the one being retried), and plain flag/toggle
  // sets. Deliberately NOT applied to createUser/createHospital/
  // createOrganization: each allocates a brand-new resource identity on
  // every call (a new Auth uid, or Firestore's own auto-ID via .add()), so
  // a blind retry after a lost response risks either a silent duplicate
  // (createHospital) or, worse, a half-created resource a retry can't
  // detect (createOrganization's multi-step, non-transactional writes) —
  // fixing those needs real backend idempotency work (e.g. a
  // caller-supplied idempotency key), not just this wrapper.
  Future<T> _callWithColdStartRetry<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on FirebaseFunctionsException catch (error) {
      if (error.code != 'internal') rethrow;
      return call();
    }
  }

  // Same as [_callWithColdStartRetry], but for delete-style callables that
  // remove a resource entirely: additionally treats a not-found on the
  // retry as success, not a real failure. That specific outcome means the
  // FIRST attempt actually reached the server and completed (the target is
  // genuinely gone) before its response was lost in transit — a retry
  // that finds nothing left to delete is proof of success, not an error to
  // surface as a confusing "no longer exists" message right after the
  // admin asked to delete it. Requires the callable's own server-side
  // implementation to be genuinely idempotent for this to be safe, not
  // just hopeful — see deleteUser/deleteHospital's own comments in
  // functions/src/admin.ts.
  Future<void> _callDeleteWithColdStartRetry(Future<void> Function() call) async {
    try {
      await call();
    } on FirebaseFunctionsException catch (error) {
      if (error.code != 'internal') rethrow;
      try {
        await call();
      } on FirebaseFunctionsException catch (retryError) {
        if (retryError.code != 'not-found') rethrow;
      }
    }
  }

  // Not retried — see _callWithColdStartRetry's own doc comment: createUser
  // mints a brand-new Auth uid on every call, so a blind retry after a
  // lost response risks a half-created account (Auth user exists, no
  // Firestore profile, no welcome email) that this app has no way to
  // detect or repair.
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
    return _callWithColdStartRetry(
      () => _functions.httpsCallable('setUserRole').call<Map<Object?, Object?>>({
        'email': email,
        'role': role.wireValue,
      }),
    );
  }

  Future<void> removeUserRole({required String email, required UserRole role}) {
    return _callWithColdStartRetry(
      () => _functions.httpsCallable('removeUserRole').call<Map<Object?, Object?>>({
        'email': email,
        'role': role.wireValue,
      }),
    );
  }

  Future<ManagedUser> updateUser({
    required String uid,
    String? email,
    String? firstName,
    String? lastName,
  }) async {
    final callable = _functions.httpsCallable('updateUser');
    final result = await _callWithColdStartRetry(
      () => callable.call<Map<Object?, Object?>>({
        'uid': uid,
        'email': ?email,
        'firstName': ?firstName,
        'lastName': ?lastName,
      }),
    );
    return ManagedUser.fromJson(result.data);
  }

  Future<void> deleteUser(String uid) {
    final callable = _functions.httpsCallable('deleteUser');
    return _callDeleteWithColdStartRetry(() => callable.call<Map<Object?, Object?>>({'uid': uid}));
  }

  Future<void> setUserDisabled({required String uid, required bool disabled}) {
    return _callWithColdStartRetry(
      () => _functions.httpsCallable('setUserDisabled').call<Map<Object?, Object?>>({
        'uid': uid,
        'disabled': disabled,
      }),
    );
  }

  // Safe to retry in the sense that matters (no data corruption — its only
  // effect is sending an email, no state mutation) even though it isn't
  // perfectly idempotent: the rare case where the first attempt's send
  // actually succeeded before the connection died means the target gets
  // one extra invite email, an acceptable minor side effect for an
  // explicit, infrequent admin action — not the half-created/duplicated-
  // resource risk that keeps createUser/createHospital/createOrganization
  // out of this wrapper.
  Future<void> resendInvite(String uid) {
    return _callWithColdStartRetry(
      () => _functions.httpsCallable('resendInvite').call<Map<Object?, Object?>>({'uid': uid}),
    );
  }

  // The only real recovery path for a user locked out after losing their
  // authenticator device — see resetUserMfa's own doc comment in
  // functions/src/admin.ts for why self-service can't fix that case.
  Future<void> resetUserMfa(String uid) {
    return _callWithColdStartRetry(
      () => _functions.httpsCallable('resetUserMfa').call<Map<Object?, Object?>>({'uid': uid}),
    );
  }

  // Omit beforeTimestampMs for the first (most recent) page; pass the
  // previous page's oldest entry's timestamp to page further back. A pure
  // read — always safe to retry regardless of idempotency concerns.
  Future<AuditLogPage> listAuditLog({int? beforeTimestampMs}) async {
    final callable = _functions.httpsCallable('listAuditLog');
    final result = await _callWithColdStartRetry(
      () => callable.call<Map<Object?, Object?>>({'beforeTimestampMs': ?beforeTimestampMs}),
    );
    return AuditLogPage.fromJson(result.data);
  }

  // A pure read — always safe to retry regardless of idempotency concerns.
  Future<List<ManagedUser>> listUsersWithRoles() async {
    final callable = _functions.httpsCallable('listUsersWithRoles');
    final result = await _callWithColdStartRetry(() => callable.call<List<Object?>>());
    return result.data
        .whereType<Map<Object?, Object?>>()
        .map(ManagedUser.fromJson)
        .toList();
  }

  // Not retried — mints a new Firestore doc via .add() on every call (a
  // fresh random ID each time), so a blind retry after a lost response
  // wouldn't even get a clean "already exists" signal like createUser
  // does; it would just silently create a second, duplicate hospital.
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
    final result = await _callWithColdStartRetry(
      () => callable.call<Map<Object?, Object?>>({
        'hospitalId': hospitalId,
        'name': ?name,
        'address': ?address,
      }),
    );
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
    final callable = _functions.httpsCallable('deleteHospital');
    return _callDeleteWithColdStartRetry(
      () => callable.call<Map<Object?, Object?>>({'hospitalId': hospitalId}),
    );
  }

  // Not retried — see _callWithColdStartRetry's own doc comment:
  // createUser's own mid-sequence Auth account (for the org's first admin)
  // has the exact same half-created risk here, compounded by the org
  // document and user profile being separate, non-transactional writes
  // after it.
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
    return _callWithColdStartRetry(
      () => _functions.httpsCallable('setOrganizationRetention').call<Map<Object?, Object?>>({
        'retainAllData': retainAllData,
      }),
    );
  }

  Future<void> setOrganizationCountry(String country) {
    return _callWithColdStartRetry(
      () => _functions.httpsCallable('setOrganizationCountry').call<Map<Object?, Object?>>({
        'country': country,
      }),
    );
  }

  // Turns on real per-organization Cloud KMS envelope encryption for
  // patient.name/healthcareNumber (functions/src/kms.ts, functions/src/
  // patients.ts) — Firestore's own CMEK is whole-database and can only be
  // set at creation, so it can't be toggled per-org on this app's shared
  // database; this is the application-level equivalent. Safe to retry:
  // the callable itself reuses an existing KMS key rather than
  // re-provisioning one on a re-toggle (see its own comment in
  // functions/src/admin.ts).
  Future<void> setOrganizationCmekPreference(bool cmekRequested) {
    return _callWithColdStartRetry(
      () => _functions.httpsCallable('setOrganizationCmekPreference').call<Map<Object?, Object?>>({
        'cmekRequested': cmekRequested,
      }),
    );
  }

  // Gates only the patient-record actions (create/update/complete/delete/
  // decrypt) logged from functions/src/patients.ts — see audit.ts's
  // GATED_ACTIONS. Org/user/hospital management actions are always logged
  // regardless of this setting.
  Future<void> setOrganizationAuditLogging(bool auditLoggingEnabled) {
    return _callWithColdStartRetry(
      () => _functions.httpsCallable('setOrganizationAuditLogging').call<Map<Object?, Object?>>({
        'auditLoggingEnabled': auditLoggingEnabled,
      }),
    );
  }

  // Gates exportPatientFhirBundle (functions/src/patients.ts) — off by
  // default, opt-in only. The export callable re-checks this itself, so
  // this toggle is purely a capability switch, not the only enforcement.
  Future<void> setOrganizationFhirExportEnabled(bool fhirExportEnabled) {
    return _callWithColdStartRetry(
      () => _functions.httpsCallable('setOrganizationFhirExportEnabled').call<Map<Object?, Object?>>({
        'fhirExportEnabled': fhirExportEnabled,
      }),
    );
  }
}

final adminServiceProvider = Provider<AdminService>((ref) {
  return AdminService(ref.watch(firebaseFunctionsProvider));
});
