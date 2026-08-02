/// Mirrors `apps/physician/src/app/classes/active-location.ts` — bundles a
/// patient's current EMS location fix alongside the immediately-preceding
/// one, so the map marker can animate (lerp) between them over the real
/// elapsed wall-clock gap. See [EmsLocationService] for how the "previous"
/// fields get carried forward across Firestore snapshots.
class ActiveLocation {
  const ActiveLocation({
    required this.patientId,
    required this.updatedAtMs,
    this.latitude,
    this.longitude,
    this.previousLatitude,
    this.previousLongitude,
    this.previousUpdatedAtMs,
  });

  final String patientId;
  final int updatedAtMs;
  final double? latitude;
  final double? longitude;
  final double? previousLatitude;
  final double? previousLongitude;
  final int? previousUpdatedAtMs;
}
