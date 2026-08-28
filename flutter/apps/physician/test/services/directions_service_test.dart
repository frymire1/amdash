import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:physician/services/directions_service.dart';

class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

class _MockHttpsCallable extends Mock implements HttpsCallable {}

class _MockHttpsCallableResult<T> extends Mock implements HttpsCallableResult<T> {}

void main() {
  setUpAll(() {
    registerFallbackValue(<String, Object?>{});
  });

  group('DirectionsCacheController', () {
    test('starts empty', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(directionsCacheProvider), isEmpty);
    });

    test('entryFor a null patientId is always null, without touching state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(directionsCacheProvider.notifier);
      expect(controller.entryFor(null), isNull);
    });

    test('entryFor an unknown patientId is null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(directionsCacheProvider.notifier);
      expect(controller.entryFor('patient-1'), isNull);
    });

    test('store then entryFor round-trips, and does not clobber a different patient\'s entry', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(directionsCacheProvider.notifier);

      const entry1 = DirectionsCacheEntry(
        result: DirectionsResult(polylinePoints: [], durationText: '5 min', distanceText: '2 km'),
        requestedAtMs: 1000,
        origin: LatLng(45.4, -75.7),
      );
      const entry2 = DirectionsCacheEntry(
        result: DirectionsResult(polylinePoints: [], durationText: '10 min', distanceText: '4 km'),
        requestedAtMs: 2000,
        origin: LatLng(45.5, -75.8),
      );

      controller.store('patient-1', entry1);
      controller.store('patient-2', entry2);

      expect(controller.entryFor('patient-1'), same(entry1));
      expect(controller.entryFor('patient-2'), same(entry2));
    });
  });

  group('DirectionsService.fetchDirections', () {
    late _MockFirebaseFunctions functions;
    late _MockHttpsCallable callable;
    late DirectionsService service;

    setUp(() {
      functions = _MockFirebaseFunctions();
      callable = _MockHttpsCallable();
      when(() => functions.httpsCallable('fetchDirections')).thenReturn(callable);
      service = DirectionsService(functions);
    });

    test('sends origin/destination lat/lng and maps a found response', () async {
      final response = _MockHttpsCallableResult<Object?>();
      when(() => response.data).thenReturn({
        'found': true,
        'polylinePoints': [
          [45.40, -75.70],
          [45.41, -75.71],
        ],
        'durationText': '12 mins',
        'distanceText': '5.2 km',
      });
      when(() => callable.call<Object?>(any())).thenAnswer((_) async => response);

      final result = await service.fetchDirections(
        origin: const LatLng(45.40, -75.70),
        destination: const LatLng(45.41, -75.71),
      );

      expect(result, isNotNull);
      expect(result!.polylinePoints, [const LatLng(45.40, -75.70), const LatLng(45.41, -75.71)]);
      expect(result.durationText, '12 mins');
      expect(result.distanceText, '5.2 km');
      verify(
        () => callable.call<Object?>({
          'originLat': 45.40,
          'originLng': -75.70,
          'destinationLat': 45.41,
          'destinationLng': -75.71,
        }),
      ).called(1);
    });

    test('returns null when the callable reports found: false', () async {
      final response = _MockHttpsCallableResult<Object?>();
      when(() => response.data).thenReturn({'found': false});
      when(() => callable.call<Object?>(any())).thenAnswer((_) async => response);

      final result = await service.fetchDirections(
        origin: const LatLng(45.40, -75.70),
        destination: const LatLng(45.41, -75.71),
      );

      expect(result, isNull);
    });
  });
}
