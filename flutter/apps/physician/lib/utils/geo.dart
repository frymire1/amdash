import 'dart:math';

import 'package:google_maps_flutter/google_maps_flutter.dart';

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

/// Smallest bounding box containing every point in [points] — extracted
/// from `patient_viewer.dart`'s own (formerly private) `_boundsFromPoints`,
/// pure math with no font/platform coupling, so it's safe to share directly
/// (unlike that file's marker-icon rendering — see
/// `multiple_ambulance_view.dart`'s own doc comment on why that stays
/// duplicated instead). Used by both `PatientViewer`'s Directions-route
/// camera fit and `MultipleAmbulanceView`'s fleet camera fit. [points] must
/// be non-empty.
LatLngBounds boundsFromPoints(List<LatLng> points) {
  var minLat = points.first.latitude;
  var maxLat = points.first.latitude;
  var minLng = points.first.longitude;
  var maxLng = points.first.longitude;
  for (final point in points) {
    if (point.latitude < minLat) minLat = point.latitude;
    if (point.latitude > maxLat) maxLat = point.latitude;
    if (point.longitude < minLng) minLng = point.longitude;
    if (point.longitude > maxLng) maxLng = point.longitude;
  }
  return LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
}
