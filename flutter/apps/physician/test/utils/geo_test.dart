import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:physician/utils/geo.dart';

// R * (1 degree in radians) — a pure latitude-only (or, at the equator,
// pure longitude-only) haversine distance reduces to this exact closed
// form, since with dLng == 0, a == sin²(dLat/2) and
// 2*atan2(sin(x), cos(x)) == x for x in [-pi, pi] — no floating-point
// approximation needed to know the expected value here, unlike a
// landmark-to-landmark real-world distance this test would otherwise
// have to trust without independently verifying.
const _oneDegreeMeters = 6371000.0 * pi / 180;

void main() {
  group('distanceMeters', () {
    test('is zero between a point and itself', () {
      expect(distanceMeters(45.4215, -75.6972, 45.4215, -75.6972), 0);
    });

    test('exactly R * dLat(radians) for a pure latitude change', () {
      final distance = distanceMeters(0, 0, 1, 0);
      expect(distance, closeTo(_oneDegreeMeters, 0.01));
    });

    test('exactly R * dLng(radians) for a pure longitude change at the equator', () {
      final distance = distanceMeters(0, 0, 0, 1);
      expect(distance, closeTo(_oneDegreeMeters, 0.01));
    });

    test('is symmetric regardless of point order', () {
      final forward = distanceMeters(45.4215, -75.6972, 45.5017, -75.5636);
      final backward = distanceMeters(45.5017, -75.5636, 45.4215, -75.6972);
      expect(forward, closeTo(backward, 0.001));
    });

    test('handles points straddling the equator/prime meridian', () {
      final distance = distanceMeters(0.01, -0.01, -0.01, 0.01);
      expect(distance, greaterThan(0));
      expect(distance, lessThan(_oneDegreeMeters));
    });
  });
}
