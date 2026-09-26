/// Physician's fleet-wide counterpart to `ActiveLocation` — same fix-level
/// shape, but keyed by `ambulanceId` (a device-local identifier the EMS app
/// asks for at sign-in, see ems/lib/screens/ambulance_id_screen.dart) rather
/// than `patientId`, and with no `previous*` lerp-animation fields:
/// ambulances publish far less often (60s idle / 15s transporting — see
/// ems_tracking_service.dart's own `_idleAmbulancePublishInterval`) than a
/// single vehicle's own marker glide needs to look smooth, so
/// `AmbulanceLocationController` doesn't carry a previous fix forward the
/// way `EmsLocationController` does — see that class's own doc comment.
///
/// Kept as its own class rather than folding into `ActiveLocation`: that
/// class is small, stable, already fully covered, and used throughout
/// `patient_viewer.dart`/`patient_list.dart` — the two classes' identity
/// fields differ anyway (`ambulanceId` vs `patientId`), so there's no real
/// reuse benefit to justify touching an already-proven surface.
class ActiveAmbulanceLocation {
  const ActiveAmbulanceLocation({
    required this.ambulanceId,
    required this.latitude,
    required this.longitude,
    required this.isTransporting,
    required this.updatedAtMs,
    this.phoneNumber = '',
  });

  final String ambulanceId;
  final double latitude;
  final double longitude;
  final bool isTransporting;
  final int updatedAtMs;

  /// The best phone number to reach this ambulance's crew, as entered on
  /// the EMS device at sign-in (see ems/lib/screens/ambulance_id_screen.dart)
  /// — empty string, not null, for a doc written before this field
  /// existed (see AmbulanceLocationController._onSnapshot's own fallback).
  final String phoneNumber;
}
