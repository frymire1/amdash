import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../firebase/firebase_providers.dart';
import '../models/patient.dart';

/// A resolved `name`/`healthcareNumber` pair for one patient — either
/// value may be null if that specific field wasn't returned (patient not
/// found, or belongs to a different org — see `decryptPatientFields`'s own
/// doc comment for why those two cases share a shape).
///
/// [nameFingerprint]/[healthcareNumberFingerprint] record which
/// `PatientField.fingerprint` this value corresponds to — null for a field
/// that was never encrypted in the first place. Comparing these against a
/// patient's *current* fingerprint (see [pullMissingDecryptedPatientFields])
/// is what lets a cached value be told apart from data that's since been
/// edited, rather than trusting "this patient id is in the cache" alone.
class DecryptedPatientFields {
  const DecryptedPatientFields({this.name, this.healthcareNumber, this.nameFingerprint, this.healthcareNumberFingerprint});

  final String? name;
  final String? healthcareNumber;
  final String? nameFingerprint;
  final String? healthcareNumberFingerprint;
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
  /// fan-out on a list screen). Returned entries carry no fingerprints —
  /// [pullMissingDecryptedPatientFields] attaches those itself, from the
  /// `Patient` snapshot it was called with.
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
  return PatientDecryptionService(ref.watch(firebaseFunctionsProvider));
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

// A patient needs (re-)decrypting when either encrypted field either isn't
// cached at all, or is cached under a fingerprint that no longer matches
// the field's current one — the latter is what actually detects an edit,
// as opposed to merely "have I ever seen this patient id before."
bool _needsDecrypt(Patient patient, DecryptedPatientFields? cached) {
  if (patient.name.isEncrypted && cached?.nameFingerprint != patient.name.fingerprint) return true;
  if (patient.healthcareNumber.isEncrypted && cached?.healthcareNumberFingerprint != patient.healthcareNumber.fingerprint) {
    return true;
  }
  return false;
}

/// Fire-and-forget: finds patients in [patients] whose encrypted fields
/// are missing from the cache or stale (see [_needsDecrypt]) and
/// pulls+caches them, fingerprinted against the exact snapshot passed in
/// here. Deliberately not awaited by callers — a patient list should
/// render immediately with "Decrypting…" placeholders (see
/// [PatientFieldDisplay.display]) rather than block on this; the cache
/// update triggers its own rebuild once it resolves.
void pullMissingDecryptedPatientFields(Ref ref, List<Patient> patients) {
  final cache = ref.read(patientFieldCacheProvider);
  final toFetch = <Patient>[
    for (final patient in patients)
      if (patient.id != null && _needsDecrypt(patient, cache[patient.id])) patient,
  ];
  if (toFetch.isEmpty) return;

  // Captured now, from this exact snapshot — by the time the decrypt call
  // resolves, a *later* edit could already be in flight, and the fetched
  // plaintext must be filed under the fingerprint it actually corresponds
  // to (this pull's), not whatever's newest when the response lands.
  final fingerprintsById = {
    for (final patient in toFetch)
      patient.id!: (name: patient.name.fingerprint, healthcareNumber: patient.healthcareNumber.fingerprint),
  };

  unawaited(
    ref
        .read(patientDecryptionServiceProvider)
        .decryptFields([for (final patient in toFetch) patient.id!])
        .then((resolved) {
          final fingerprinted = {
            for (final entry in resolved.entries)
              entry.key: DecryptedPatientFields(
                name: entry.value.name,
                healthcareNumber: entry.value.healthcareNumber,
                nameFingerprint: fingerprintsById[entry.key]?.name,
                healthcareNumberFingerprint: fingerprintsById[entry.key]?.healthcareNumber,
              ),
          };
          ref.read(patientFieldCacheProvider.notifier).putAll(fingerprinted);
        })
        .catchError((Object _) {
          // Best-effort — a failed pull just leaves the "Decrypting…"
          // placeholder up; the next rebuild (new snapshot, cache change
          // elsewhere, screen revisit) retries since these ids are still
          // stale/absent in the cache.
        }),
  );
}

// Only trust a cached plaintext if it was decrypted from (or, for EMS's
// own just-saved value, written as) the exact ciphertext `field` currently
// carries. A fingerprint mismatch means the underlying value changed since
// this was cached — the raw, still-encrypted field is left alone (returns
// null) so display shows "Decrypting…" until a fresh pull resolves it,
// rather than briefly showing a stale value.
String? _resolvedValueFor(PatientField field, String? cachedValue, String? cachedFingerprint) {
  if (!field.isEncrypted || cachedValue == null) return null;
  return cachedFingerprint == field.fingerprint ? cachedValue : null;
}

/// Splices whatever's already cached (and still fingerprint-matching) in
/// [patientFieldCacheProvider] into [patients], and kicks a pull for
/// anything missing or stale. The one call physician's/EMS's own
/// patient-list providers make each time their live Firestore stream
/// emits.
List<Patient> withCachedDecryptedFields(Ref ref, List<Patient> patients) {
  pullMissingDecryptedPatientFields(ref, patients);
  final cache = ref.watch(patientFieldCacheProvider);
  return [
    for (final patient in patients)
      patient.withDecryptedFields(
        name: _resolvedValueFor(patient.name, cache[patient.id]?.name, cache[patient.id]?.nameFingerprint),
        healthcareNumber: _resolvedValueFor(
          patient.healthcareNumber,
          cache[patient.id]?.healthcareNumber,
          cache[patient.id]?.healthcareNumberFingerprint,
        ),
      ),
  ];
}
