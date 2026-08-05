import 'package:cloud_functions/cloud_functions.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

const _functionsRegion = 'northamerica-northeast2';

class DirectionsResult {
  const DirectionsResult({
    required this.polylinePoints,
    required this.durationText,
    required this.distanceText,
  });

  final List<LatLng> polylinePoints;
  final String durationText;
  final String distanceText;
}

/// Calls the `fetchDirections` Cloud Function rather than the Directions
/// REST API directly — that REST endpoint never sends CORS headers (it was
/// only ever designed for server-side/native callers), so a direct call
/// from Flutter Web fails outright with a browser CORS error. Routing
/// through a callable works uniformly on every platform and keeps the API
/// key server-side instead of embedded in client code. Mirrors what
/// `MapDirectionsService.route(...)` does in `patient-viewer.component.ts`
/// (no dedicated Angular service exists there either; the throttling logic
/// that decides *when* to call this lives in the widget/component itself,
/// see `PatientViewer`'s `_maybeRequestDirections`).
class DirectionsService {
  DirectionsService() : _functions = FirebaseFunctions.instanceFor(region: _functionsRegion);

  final FirebaseFunctions _functions;

  Future<DirectionsResult?> fetchDirections({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final response = await _functions.httpsCallable('fetchDirections').call<Object?>({
      'originLat': origin.latitude,
      'originLng': origin.longitude,
      'destinationLat': destination.latitude,
      'destinationLng': destination.longitude,
    });

    // On web, cloud_functions' JS interop hands back a map that isn't
    // cleanly assignable to Map<String, Object?> via a direct generic
    // `.call<Map<String, Object?>>()` cast — that throws at runtime
    // (silently caught by PatientViewer's try/catch). Map.from() copies
    // into a real Dart Map instead of relying on the interop object
    // satisfying that type directly.
    final data = Map<String, Object?>.from(response.data as Map);
    if (data['found'] != true) return null;

    // The Cloud Function decodes the polyline server-side and sends plain
    // [lat, lng] number pairs rather than the encoded string — a real run
    // showed the encoded string arriving corrupted through this same JSON
    // transport (points decoded to wildly wrong coordinates), so this
    // avoids relying on every byte of a codec-sensitive string surviving
    // the round trip.
    final rawPoints = data['polylinePoints'] as List<Object?>;
    final polylinePoints = rawPoints.map((point) {
      final pair = point! as List<Object?>;
      return LatLng((pair[0]! as num).toDouble(), (pair[1]! as num).toDouble());
    }).toList();

    return DirectionsResult(
      polylinePoints: polylinePoints,
      durationText: data['durationText'] as String,
      distanceText: data['distanceText'] as String,
    );
  }
}
