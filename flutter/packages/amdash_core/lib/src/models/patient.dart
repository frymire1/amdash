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
      name: data['name'] as String? ?? '',
      gender: data['gender'] as String? ?? '',
      age: data['age'],
      healthcareNumber: data['healthcareNumber'] as String? ?? '',
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

  final String? id;
  final String name;
  final String gender;
  final Object? age;
  final String healthcareNumber;
  final PatientVitals vitals;
  final PatientLocation? location;
  final String? notes;
  final String? destination;
  final String? ivSize;
  final String? ivPlacement;
  final String? treatment;
  final String? status;
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
