/// Mirrors `libs/patients/src/lib/classes/patient-vitals.ts`. Several
/// fields are `num`-or-`String` in the Angular source because EMS writes
/// the literal string `'Unknown'` for a blank field rather than omitting
/// it — represented here as `Object?` per field, resolved via
/// [isProvidedValue] at display time (mirrors the Angular apps'
/// `isProvided()` helper, duplicated in `patient-card`/`patient-viewer`).
class PatientVitals {
  const PatientVitals({
    required this.heartRate,
    required this.bloodPressure,
    required this.oxygen,
    required this.temperature,
    this.respiratoryRate,
    this.gcs,
  });

  factory PatientVitals.fromFirestore(Map<String, Object?> data) {
    return PatientVitals(
      heartRate: data['heartRate'],
      bloodPressure: data['bloodPressure'] as String? ?? '',
      oxygen: data['oxygen'],
      temperature: data['temperature'],
      respiratoryRate: (data['respiratoryRate'] as num?)?.toInt(),
      gcs: (data['gcs'] as num?)?.toInt(),
    );
  }

  final Object? heartRate;
  final String bloodPressure;
  final Object? oxygen;
  final Object? temperature;
  final int? respiratoryRate;
  final int? gcs;
}

/// Mirrors `libs/patients/src/lib/classes/patient-location.ts`.
class PatientLocation {
  const PatientLocation({
    required this.latitude,
    required this.longitude,
    required this.address,
  });

  factory PatientLocation.fromFirestore(Map<String, Object?> data) {
    return PatientLocation(
      latitude: (data['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (data['longitude'] as num?)?.toDouble() ?? 0,
      address: data['address'] as String? ?? '',
    );
  }

  final double latitude;
  final double longitude;
  final String address;
}

/// Represents `patient.name`/`patient.healthcareNumber` as read off
/// Firestore — either a plain string (the common case: no Canadian data
/// residency requested for this org, or a legacy record written before
/// encryption existed) or a Cloud KMS envelope-encrypted blob (shape
/// `{ __enc: 1, ... }` — see `functions/src/kms.ts`'s `EncryptedField`)
/// not yet decrypted. Call sites branch on [isEncrypted]/[plaintext]
/// rather than assuming a raw `String` or guessing a value out of the raw
/// JSON shape themselves. [isProvidedValue] below should only ever be
/// called on a resolved [plaintext], never on this wrapper directly.
class PatientField {
  const PatientField._({this.plaintext, required this.isEncrypted, this.fingerprint});

  factory PatientField.fromFirestore(Object? value) {
    if (value is String) return PatientField._(plaintext: value, isEncrypted: false);
    if (value is Map) {
      final ciphertext = value['ciphertext'];
      return PatientField._(isEncrypted: true, fingerprint: ciphertext is String ? ciphertext : null);
    }
    return const PatientField._(plaintext: '', isEncrypted: false);
  }

  /// A `PatientField` already holding a known plaintext string — used to
  /// splice a decrypted value (from `PatientDecryptionService`'s cache)
  /// back into a [Patient] for display, without re-touching Firestore.
  const PatientField.resolved(String value) : plaintext = value, isEncrypted = false, fingerprint = null;

  /// The real value, once known — always non-null for a plain/legacy
  /// field; null only while [isEncrypted] and not yet resolved by
  /// `PatientDecryptionService`'s cache (see amdash_core's
  /// `patientFieldCacheProvider`).
  final String? plaintext;
  final bool isEncrypted;

  /// The raw encrypted blob's `ciphertext` — a fresh, effectively-unique
  /// value every time a field is (re-)encrypted, since `kms.ts` uses a
  /// random IV/DEK per call. Lets the decrypt cache tell "this patient's
  /// value changed since I last cached it" apart from "I've simply never
  /// seen this patient before" — comparing patient *id* alone can't make
  /// that distinction, and silently kept showing a pre-edit value
  /// indefinitely until this was added. Null whenever [isEncrypted] is
  /// false — nothing to fingerprint for a plain string.
  final String? fingerprint;

  bool get isResolved => plaintext != null;
}

/// Mirrors `libs/patients/src/lib/classes/patient.ts`. `status`/
/// `submittedAt` are Firestore-only fields the shared TS interface omits
/// but the physician/EMS query/order clauses rely on (see
/// `patient.service.ts`) — included here since Dart has no equivalent
/// "loosely-typed Firestore doc" convention to lean on.
class Patient {
  const Patient({
    this.id,
    required this.name,
    required this.gender,
    required this.age,
    required this.healthcareNumber,
    required this.vitals,
    this.location,
    this.notes,
    this.destination,
    this.ivSize,
    this.ivPlacement,
    this.treatment,
    this.status,
  });

  factory Patient.fromFirestore(String id, Map<String, Object?> data) {
    final vitalsData = data['vitals'] as Map<String, Object?>? ?? const {};
    final locationData = data['location'] as Map<String, Object?>?;
    return Patient(
      id: id,
      name: PatientField.fromFirestore(data['name']),
      gender: data['gender'] as String? ?? '',
      age: data['age'],
      healthcareNumber: PatientField.fromFirestore(data['healthcareNumber']),
      vitals: PatientVitals.fromFirestore(vitalsData),
      location: locationData == null
          ? null
          : PatientLocation.fromFirestore(locationData),
      notes: data['notes'] as String?,
      destination: data['destination'] as String?,
      ivSize: data['ivSize'] as String?,
      ivPlacement: data['ivPlacement'] as String?,
      treatment: data['treatment'] as String?,
      status: data['status'] as String?,
    );
  }

  /// Returns a copy with [name]/[healthcareNumber] replaced by resolved
  /// plaintext — used once `PatientDecryptionService` returns a value for
  /// a patient whose fields arrived encrypted.
  Patient withDecryptedFields({String? name, String? healthcareNumber}) {
    return Patient(
      id: id,
      name: name != null ? PatientField.resolved(name) : this.name,
      gender: gender,
      age: age,
      healthcareNumber: healthcareNumber != null ? PatientField.resolved(healthcareNumber) : this.healthcareNumber,
      vitals: vitals,
      location: location,
      notes: notes,
      destination: destination,
      ivSize: ivSize,
      ivPlacement: ivPlacement,
      treatment: treatment,
      status: status,
    );
  }

  final String? id;
  final PatientField name;
  final String gender;
  final Object? age;
  final PatientField healthcareNumber;
  final PatientVitals vitals;
  final PatientLocation? location;
  final String? notes;
  final String? destination;
  final String? ivSize;
  final String? ivPlacement;
  final String? treatment;
  final String? status;
}

/// The single place every display site should go through for
/// `patient.name`/`patient.healthcareNumber` — centralizes the
/// "Decrypting…"/blank/real-value tri-state so it isn't hand-rolled
/// differently across patient_card.dart/patient_viewer.dart/
/// patient_summary_card.dart.
extension PatientFieldDisplay on PatientField {
  /// [notAddedText] lets call sites keep their own copy for the "blank"
  /// case (different screens phrase it differently — e.g. "Not added yet"
  /// vs. "Not added by EMS yet"); the "still decrypting" case is always
  /// the same message everywhere.
  String display({String notAddedText = 'Not added yet'}) {
    final value = plaintext;
    if (value == null) return 'Decrypting…';
    return isProvidedValue(value) ? value : notAddedText;
  }

  bool get isProvided {
    final value = plaintext;
    return value != null && isProvidedValue(value);
  }
}

/// Mirrors the `isProvided()` helper duplicated in
/// `patient-card.component.ts`/`patient-viewer.component.ts`: a field
/// counts as "provided" if it's a number, or a non-empty string that isn't
/// the literal blank-field sentinel `'Unknown'`.
bool isProvidedValue(Object? value) {
  if (value is num) return true;
  if (value is String) return value.isNotEmpty && value != 'Unknown';
  return false;
}
