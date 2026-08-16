import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/patient.dart';

/// Every callable Cloud Function this hits runs in this region — must
/// match `REGION` in `functions/src/shared.ts`.
const _functionsRegion = 'northamerica-northeast2';

/// A resolved `name`/`healthcareNumber` pair for one patient — either
/// value may be null if that specific field wasn't returned (patient not
/// found, or belongs to a different org — see `decryptPatientFields`'s own
/// doc comment for why those two cases share a shape).
class DecryptedPatientFields {
  const DecryptedPatientFields({this.name, this.healthcareNumber});

  final String? name;
  final String? healthcareNumber;
}

/// Wraps `decryptPatientFields` (`functions/src/patients.ts`) — the pull
/// path for any patient field that arrived Cloud KMS-encrypted (see
/// `PatientField`). Always safe to call regardless of whether a given
/// patient's fields are actually encrypted; the function itself passes
/// plain/legacy strings straight through, so callers never need to check
/// first.
class PatientDecryptionService {
  PatientDecryptionService(this._functions);

  final FirebaseFunctions _functions;

  /// Batched — one round trip for however many patient ids need
  /// resolving, rather than one call per patient (avoids an N-request
  /// fan-out on a list screen).
  Future<Map<String, DecryptedPatientFields>> decryptFields(List<String> patientIds) async {
    if (patientIds.isEmpty) return const {};

    final callable = _functions.httpsCallable('decryptPatientFields');
    final result = await callable.call<Map<Object?, Object?>>({'patientIds': patientIds});
    final rawResults = result.data['results'];
    if (rawResults is! List) return const {};

    final resolved = <String, DecryptedPatientFields>{};
    for (final entry in rawResults.whereType<Map<Object?, Object?>>()) {
      final patientId = entry['patientId'] as String?;
      if (patientId == null) continue;
      resolved[patientId] = DecryptedPatientFields(
        name: entry['name'] as String?,
        healthcareNumber: entry['healthcareNumber'] as String?,
      );
    }
    return resolved;
  }
}

final patientDecryptionServiceProvider = Provider<PatientDecryptionService>((ref) {
  return PatientDecryptionService(FirebaseFunctions.instanceFor(region: _functionsRegion));
});

/// In-memory cache of decrypted patient fields, keyed by patient id —
/// shared by physician and EMS so both apps' patient-list providers can
/// read a resolved plaintext without each maintaining their own cache.
/// Never persisted (that would defeat the point of encrypting at rest)
/// and never the source of truth for the EMS edit-form prefill, which
/// always calls [PatientDecryptionService] directly for a
/// guaranteed-fresh value instead of trusting whatever's cached here.
class PatientFieldCache extends Notifier<Map<String, DecryptedPatientFields>> {
  @override
  Map<String, DecryptedPatientFields> build() => const {};

  void putAll(Map<String, DecryptedPatientFields> entries) {
    if (entries.isEmpty) return;
    state = {...state, ...entries};
  }
}

final patientFieldCacheProvider = NotifierProvider<PatientFieldCache, Map<String, DecryptedPatientFields>>(
  PatientFieldCache.new,
);

/// Fire-and-forget: finds patients in [patients] with an encrypted,
/// not-yet-cached field and pulls+caches them. Deliberately not awaited by
/// callers — a patient list should render immediately with "Decrypting…"
/// placeholders (see [PatientFieldDisplay.display]) rather than block on
/// this; the cache update triggers its own rebuild once it resolves.
void pullMissingDecryptedPatientFields(Ref ref, List<Patient> patients) {
  final cache = ref.read(patientFieldCacheProvider);
  final missingIds = <String>{
    for (final patient in patients)
      if (patient.id != null &&
          (patient.name.isEncrypted || patient.healthcareNumber.isEncrypted) &&
          !cache.containsKey(patient.id))
        patient.id!,
  };
  if (missingIds.isEmpty) return;

  unawaited(
    ref
        .read(patientDecryptionServiceProvider)
        .decryptFields(missingIds.toList())
        .then((resolved) => ref.read(patientFieldCacheProvider.notifier).putAll(resolved))
        .catchError((Object _) {
          // Best-effort — a failed pull just leaves the "Decrypting…"
          // placeholder up; the next rebuild (new snapshot, cache change
          // elsewhere, screen revisit) retries since these ids are still
          // absent from the cache.
        }),
  );
}

/// Splices whatever's already cached in [patientFieldCacheProvider] into
/// [patients], and kicks a pull for anything still missing. The one call
/// physician's/EMS's own patient-list providers make each time their live
/// Firestore stream emits.
List<Patient> withCachedDecryptedFields(Ref ref, List<Patient> patients) {
  pullMissingDecryptedPatientFields(ref, patients);
  final cache = ref.watch(patientFieldCacheProvider);
  return [
    for (final patient in patients)
      patient.withDecryptedFields(
        name: cache[patient.id]?.name,
        healthcareNumber: cache[patient.id]?.healthcareNumber,
      ),
  ];
}
