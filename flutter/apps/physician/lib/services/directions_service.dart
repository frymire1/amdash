import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

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

/// Raw wrapper around the Directions REST API — mirrors what
/// `MapDirectionsService.route(...)` does in `patient-viewer.component.ts`
/// (no dedicated Angular service exists there either; the throttling logic
/// that decides *when* to call this lives in the widget/component itself,
/// see `PatientViewer`'s `_maybeRequestDirections`).
class DirectionsService {
  DirectionsService(this._apiKey);

  final String _apiKey;

  Future<DirectionsResult?> fetchDirections({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
      'origin': '${origin.latitude},${origin.longitude}',
      'destination': '${destination.latitude},${destination.longitude}',
      'mode': 'driving',
      'key': _apiKey,
    });

    final response = await http.get(uri);
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body) as Map<String, Object?>;
    if (data['status'] != 'OK') return null;

    final routes = data['routes'] as List<Object?>;
    if (routes.isEmpty) return null;
    final route = routes.first as Map<String, Object?>;
    final legs = route['legs'] as List<Object?>;
    if (legs.isEmpty) return null;
    final leg = legs.first as Map<String, Object?>;
    final overviewPolyline = route['overview_polyline'] as Map<String, Object?>;

    return DirectionsResult(
      polylinePoints: _decodePolyline(overviewPolyline['points'] as String),
      durationText: (leg['duration'] as Map<String, Object?>)['text'] as String,
      distanceText: (leg['distance'] as Map<String, Object?>)['text'] as String,
    );
  }

  // Standard Google encoded-polyline algorithm decoder.
  List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    var index = 0;
    var lat = 0;
    var lng = 0;

    while (index < encoded.length) {
      var result = 0;
      var shift = 0;
      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      result = 0;
      shift = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }

    return points;
  }
}
