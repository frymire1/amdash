import 'dart:math';

const _earthRadiusM = 6371000.0;

/// Haversine distance in meters. Angular duplicates this (once in km in
/// `patient-list.component.ts`, once in meters in `patient-viewer.component.ts`)
/// — consolidated into one util here, used by both the distance-sort in
/// [PatientList] and the Directions-refresh distance throttle in
/// [PatientViewer].
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  final dLat = _degToRad(lat2 - lat1);
  final dLng = _degToRad(lng2 - lng1);
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(_degToRad(lat1)) * cos(_degToRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return _earthRadiusM * c;
}

double _degToRad(double deg) => deg * (pi / 180);
