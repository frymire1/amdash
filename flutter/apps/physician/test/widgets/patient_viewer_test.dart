import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:physician/classes/active_location.dart';
import 'package:physician/services/directions_service.dart';
import 'package:physician/services/ems_location_service.dart';
import 'package:physician/widgets/patient_viewer.dart';

import '../support/mock_google_maps.dart';
import '../support/pump_app.dart';

class _MockDirectionsService extends Mock implements DirectionsService {}

// Minimal fakes — both real Notifiers do genuine Firestore/collectionGroup
// work in build(), which a plain `flutter test` has no backing for; these
// just carry whatever canned state/route each test needs, with a `setState`
// escape hatch so tests can simulate a genuine change (not just an initial
// value) — ref.listen only fires on those, matching the real Firestore
// snapshot stream this stands in for.
class _FakeEmsLocationController extends EmsLocationController {
  _FakeEmsLocationController(this._initial);
  final EmsLocationState _initial;

  @override
  EmsLocationState build() => _initial;

  void setState(EmsLocationState next) => state = next;
}

class _FakeDirectionsCacheController extends DirectionsCacheController {
  _FakeDirectionsCacheController([this._initial = const {}]);
  final Map<String, DirectionsCacheEntry> _initial;

  @override
  Map<String, DirectionsCacheEntry> build() => _initial;
}

Patient _patient({String? id = 'patient-1', String destination = ''}) {
  return Patient(
    id: id,
    name: const PatientField.resolved('Jordan Lee'),
    gender: 'Female',
    age: 42,
    healthcareNumber: const PatientField.resolved('HC-1'),
    vitals: const PatientVitals(heartRate: 90, bloodPressure: '120/80', oxygen: 98, temperature: 37),
    destination: destination,
  );
}

const _hospital = Hospital(
  id: 'hosp-1',
  name: 'Ottawa Civic',
  address: '1053 Carling Ave',
  latitude: 45.4,
  longitude: -75.75,
  organizationId: 'org-1',
);

ActiveLocation _fix({
  String patientId = 'patient-1',
  required int updatedAtMs,
  double latitude = 45.41,
  double longitude = -75.69,
  double? previousLatitude,
  double? previousLongitude,
  int? previousUpdatedAtMs,
}) {
  return ActiveLocation(
    patientId: patientId,
    updatedAtMs: updatedAtMs,
    latitude: latitude,
    longitude: longitude,
    previousLatitude: previousLatitude,
    previousLongitude: previousLongitude,
    previousUpdatedAtMs: previousUpdatedAtMs,
  );
}

DirectionsResult _directionsResult({List<LatLng>? points}) {
  return DirectionsResult(
    polylinePoints: points ?? const [LatLng(45.40, -75.70), LatLng(45.42, -75.68)],
    durationText: '12 mins',
    distanceText: '5.2 km',
  );
}

void main() {
  setUpAll(() {
    registerGoogleMapsFallbackValues();
    registerFallbackValue(const LatLng(0, 0));
  });

  late _MockDirectionsService directionsService;
  late MockGoogleMapsFlutterPlatform mapPlatform;

  setUp(() {
    mapPlatform = installMockGoogleMaps();
    directionsService = _MockDirectionsService();
  });

  Future<_FakeEmsLocationController> pumpViewer(
    WidgetTester tester, {
    Patient? patient,
    Widget? leading,
    List<Hospital> hospitals = const [],
    EmsLocationState emsState = const EmsLocationState(hasLoadedOnce: true),
    Map<String, DirectionsCacheEntry> cachedRoutes = const {},
  }) async {
    final controller = _FakeEmsLocationController(emsState);
    await pumpApp(
      tester,
      PatientViewer(patient: patient, leading: leading, directionsService: directionsService),
      overrides: [
        hospitalsProvider.overrideWith((ref) => Stream.value(hospitals)),
        emsLocationProvider.overrideWith(() => controller),
        directionsCacheProvider.overrideWith(() => _FakeDirectionsCacheController(cachedRoutes)),
      ],
    );
    return controller;
  }

  group('no patient selected', () {
    testWidgets('shows the empty state', (tester) async {
      await pumpViewer(tester, patient: null);
      await tester.pumpAndSettle();

      expect(find.text('Select a patient to view details'), findsOneWidget);
    });

    testWidgets('renders leading above the empty state when given', (tester) async {
      await pumpViewer(tester, patient: null, leading: const Text('mobile-back-button'));
      await tester.pumpAndSettle();

      expect(find.text('mobile-back-button'), findsOneWidget);
      expect(find.text('Select a patient to view details'), findsOneWidget);
    });
  });

  group('patient info text', () {
    testWidgets('provided age/gender render as-is; missing ones show "unknown"', (tester) async {
      await pumpViewer(tester, patient: _patient());
      await tester.pumpAndSettle();

      expect(find.textContaining('42 years'), findsOneWidget);
      expect(find.textContaining('Female'), findsOneWidget);
    });

    testWidgets('unprovided age/gender show the unknown fallback', (tester) async {
      final patient = Patient(
        id: 'patient-1',
        name: const PatientField.resolved('Jordan Lee'),
        gender: '',
        age: 'Unknown',
        healthcareNumber: const PatientField.resolved('HC-1'),
        vitals: const PatientVitals(heartRate: null, bloodPressure: '', oxygen: null, temperature: null),
      );
      await pumpViewer(tester, patient: patient);
      await tester.pumpAndSettle();

      expect(find.textContaining('Age: '), findsOneWidget);
      expect(find.textContaining('Gender: '), findsOneWidget);
      expect(find.textContaining('unknown'), findsWidgets);
    });

    testWidgets('leading also renders above a real patient (not just the empty state)', (tester) async {
      await pumpViewer(tester, patient: _patient(), leading: const Text('mobile-back-button'));
      await tester.pumpAndSettle();

      expect(find.text('mobile-back-button'), findsOneWidget);
    });

    testWidgets('provided notes render their own card', (tester) async {
      final patient = Patient(
        id: 'patient-1',
        name: const PatientField.resolved('Jordan Lee'),
        gender: 'Female',
        age: 42,
        healthcareNumber: const PatientField.resolved('HC-1'),
        vitals: const PatientVitals(heartRate: 90, bloodPressure: '120/80', oxygen: 98, temperature: 37),
        notes: 'Allergic to penicillin',
      );
      await pumpViewer(tester, patient: patient);
      await tester.pumpAndSettle();

      expect(find.text('Patient Notes'), findsOneWidget);
      expect(find.text('Allergic to penicillin'), findsOneWidget);
    });
  });

  group('no tracked location', () {
    testWidgets('never shown a location: no map card at all', (tester) async {
      await pumpViewer(tester, patient: _patient(destination: 'Ottawa Civic'), hospitals: const [_hospital]);
      await tester.pumpAndSettle();

      expect(find.byType(GoogleMap), findsNothing);
    });
  });

  group('destination hospital lookup', () {
    testWidgets('matches by name, showing both vehicle and hospital markers', (tester) async {
      // A destination match on an active/stale patient makes build() itself
      // proactively call _maybeRequestDirections — without a resolving
      // stub, fetchDirections's unstubbed MissingStubError gets silently
      // swallowed by its own catch(_), leaving directionsResult null
      // forever and the loading-blur's indeterminate CircularProgressIndicator
      // ticking perpetually, which pumpAndSettle() would never see settle
      // (same never-pumpAndSettle-across-an-indeterminate-spinner rule as
      // everywhere else this session — except here it's not transient, it
      // never clears at all without a stub).
      when(
        () => directionsService.fetchDirections(origin: any(named: 'origin'), destination: any(named: 'destination')),
      ).thenAnswer((_) async => _directionsResult());

      await pumpViewer(
        tester,
        patient: _patient(destination: 'Ottawa Civic'),
        hospitals: const [_hospital],
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.markers.map((m) => m.markerId.value), containsAll(['vehicle', 'hospital']));
    });

    testWidgets('no destination match shows only the vehicle marker', (tester) async {
      await pumpViewer(
        tester,
        patient: _patient(destination: 'Some Other Hospital'),
        hospitals: const [_hospital],
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.markers.map((m) => m.markerId.value), ['vehicle']);
    });
  });

  group('active vs. stale status text', () {
    testWidgets('active shows the live coordinates', (tester) async {
      await pumpViewer(
        tester,
        patient: _patient(),
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {
            'patient-1': EmsTrackingInfo(
              status: EmsTrackingStatus.active,
              location: _fix(updatedAtMs: 1000, latitude: 45.4123, longitude: -75.6987),
            ),
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Live position: 45.4123, -75.6987'), findsOneWidget);
    });

    testWidgets('stale shows the last-updated-at time instead', (tester) async {
      final updatedAt = DateTime(2024, 3, 1, 14, 30, 0);
      await pumpViewer(
        tester,
        patient: _patient(),
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {
            'patient-1': EmsTrackingInfo(
              status: EmsTrackingStatus.stale,
              location: _fix(updatedAtMs: updatedAt.millisecondsSinceEpoch),
            ),
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Last updated at:'), findsOneWidget);
      expect(find.textContaining('Live position:'), findsNothing);
    });
  });

  group('_onLocationChanged', () {
    testWidgets('a change to no position clears the map card', (tester) async {
      final controller = await pumpViewer(
        tester,
        patient: _patient(),
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GoogleMap), findsOneWidget);

      controller.setState(
        const EmsLocationState(hasLoadedOnce: true, info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.noData)}),
      );
      await tester.pumpAndSettle();

      expect(find.byType(GoogleMap), findsNothing);
    });

    testWidgets('a fix with no previous fix renders immediately, no ticker involved', (tester) async {
      await pumpViewer(
        tester,
        patient: _patient(),
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {
            'patient-1': EmsTrackingInfo(
              status: EmsTrackingStatus.active,
              location: _fix(updatedAtMs: 1000, latitude: 45.5, longitude: -75.5),
            ),
          },
        ),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      final vehicle = map.markers.firstWhere((m) => m.markerId.value == 'vehicle');
      expect(vehicle.position, const LatLng(45.5, -75.5));
    });

    testWidgets('a real glide interpolates the marker via a ticker, then completes at t>=1', (tester) async {
      var now = DateTime(2024, 1, 1, 12, 0, 0);
      await withClock(Clock(() => now), () async {
        final controller = await pumpViewer(
          tester,
          patient: _patient(),
          emsState: EmsLocationState(
            hasLoadedOnce: true,
            info: {
              'patient-1': EmsTrackingInfo(
                status: EmsTrackingStatus.active,
                location: _fix(updatedAtMs: now.millisecondsSinceEpoch, latitude: 45.0, longitude: -75.0),
              ),
            },
          ),
        );
        await tester.pumpAndSettle();

        final startMs = now.millisecondsSinceEpoch;
        const durationMs = 10000;
        final endMs = startMs + durationMs;
        controller.setState(
          EmsLocationState(
            hasLoadedOnce: true,
            info: {
              'patient-1': EmsTrackingInfo(
                status: EmsTrackingStatus.active,
                location: _fix(
                  updatedAtMs: endMs,
                  latitude: 45.1,
                  longitude: -75.1,
                  previousLatitude: 45.0,
                  previousLongitude: -75.0,
                  previousUpdatedAtMs: startMs,
                ),
              ),
            },
          ),
        );
        await tester.pump();

        // Halfway through the glide, in fake-clock terms.
        now = DateTime.fromMillisecondsSinceEpoch(startMs + (durationMs ~/ 2));
        await tester.pump(const Duration(milliseconds: 16));

        final midMap = tester.widget<GoogleMap>(find.byType(GoogleMap));
        final midVehicle = midMap.markers.firstWhere((m) => m.markerId.value == 'vehicle');
        expect(midVehicle.position.latitude, closeTo(45.05, 0.01));
        expect(midVehicle.position.longitude, closeTo(-75.05, 0.01));

        // Past the end of the glide — clamped to the final fix, ticker stops.
        now = DateTime.fromMillisecondsSinceEpoch(endMs + 500);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));

        final endMap = tester.widget<GoogleMap>(find.byType(GoogleMap));
        final endVehicle = endMap.markers.firstWhere((m) => m.markerId.value == 'vehicle');
        expect(endVehicle.position, const LatLng(45.1, -75.1));
      });
    });
  });

  group('_maybeRequestDirections', () {
    testWidgets('no destination hospital: never calls fetchDirections', (tester) async {
      await pumpViewer(
        tester,
        patient: _patient(destination: 'nowhere'),
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
      );
      await tester.pumpAndSettle();

      verifyNever(() => directionsService.fetchDirections(origin: any(named: 'origin'), destination: any(named: 'destination')));
    });

    testWidgets('no cached route yet: fetches, caches, and shows ETA/distance text', (tester) async {
      when(
        () => directionsService.fetchDirections(origin: any(named: 'origin'), destination: any(named: 'destination')),
      ).thenAnswer((_) async => _directionsResult());

      await pumpViewer(
        tester,
        patient: _patient(destination: 'Ottawa Civic'),
        hospitals: const [_hospital],
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
      );
      await tester.pumpAndSettle();

      verify(
        () => directionsService.fetchDirections(origin: any(named: 'origin'), destination: any(named: 'destination')),
      ).called(1);
      expect(find.textContaining('ETA: 12 mins'), findsOneWidget);
      expect(find.textContaining('Distance: 5.2 km'), findsOneWidget);
    });

    testWidgets('an already-fresh, nearby cached route is neither due by time nor distance: no fetch', (
      tester,
    ) async {
      await withClock(Clock.fixed(DateTime(2024, 1, 1, 12, 0, 5)), () async {
        await pumpViewer(
          tester,
          patient: _patient(destination: 'Ottawa Civic'),
          hospitals: const [_hospital],
          emsState: EmsLocationState(
            hasLoadedOnce: true,
            info: {
              'patient-1': EmsTrackingInfo(
                status: EmsTrackingStatus.active,
                location: _fix(updatedAtMs: DateTime(2024, 1, 1, 12, 0, 5).millisecondsSinceEpoch),
              ),
            },
          ),
          cachedRoutes: {
            'patient-1': DirectionsCacheEntry(
              result: _directionsResult(),
              requestedAtMs: DateTime(2024, 1, 1, 12, 0, 0).millisecondsSinceEpoch,
              origin: const LatLng(45.41, -75.69),
            ),
          },
        );
        await tester.pumpAndSettle();

        verifyNever(
          () => directionsService.fetchDirections(origin: any(named: 'origin'), destination: any(named: 'destination')),
        );
      });
    });

    testWidgets('due by distance (moved far from the cached origin) refetches even though it is time-fresh', (
      tester,
    ) async {
      // build()'s own proactive on-mount fetch only fires when cachedRoute
      // is null (the "no route yet at all" bootstrap case) — with a route
      // already cached (as here), only a genuine location *change* (via
      // ref.listen -> _onLocationChanged, not just the initial value)
      // re-triggers _maybeRequestDirections at all. Confirmed via a first
      // draft of this test that only set an initial value and never called
      // fetchDirections.
      when(
        () => directionsService.fetchDirections(origin: any(named: 'origin'), destination: any(named: 'destination')),
      ).thenAnswer((_) async => _directionsResult());

      await withClock(Clock.fixed(DateTime(2024, 1, 1, 12, 0, 1)), () async {
        final controller = await pumpViewer(
          tester,
          patient: _patient(destination: 'Ottawa Civic'),
          hospitals: const [_hospital],
          emsState: EmsLocationState(
            hasLoadedOnce: true,
            info: {
              'patient-1': EmsTrackingInfo(
                status: EmsTrackingStatus.active,
                location: _fix(updatedAtMs: DateTime(2024, 1, 1, 12, 0, 0).millisecondsSinceEpoch, latitude: 45.0, longitude: -75.0),
              ),
            },
          ),
          cachedRoutes: {
            'patient-1': DirectionsCacheEntry(
              result: _directionsResult(),
              requestedAtMs: DateTime(2024, 1, 1, 12, 0, 0).millisecondsSinceEpoch,
              origin: const LatLng(45.0, -75.0),
            ),
          },
        );
        await tester.pumpAndSettle();

        // Moves far from the cached entry's origin.
        controller.setState(
          EmsLocationState(
            hasLoadedOnce: true,
            info: {
              'patient-1': EmsTrackingInfo(
                status: EmsTrackingStatus.active,
                location: _fix(updatedAtMs: DateTime(2024, 1, 1, 12, 0, 1).millisecondsSinceEpoch, latitude: 46.0, longitude: -76.0),
              ),
            },
          ),
        );
        await tester.pumpAndSettle();

        verify(
          () => directionsService.fetchDirections(origin: any(named: 'origin'), destination: any(named: 'destination')),
        ).called(1);
      });
    });

    testWidgets('a failed fetch keeps showing the already-cached route, not a blank one', (tester) async {
      when(
        () => directionsService.fetchDirections(origin: any(named: 'origin'), destination: any(named: 'destination')),
      ).thenThrow(Exception('directions API down'));

      await pumpViewer(
        tester,
        patient: _patient(destination: 'Ottawa Civic'),
        hospitals: const [_hospital],
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {
            'patient-1': EmsTrackingInfo(
              status: EmsTrackingStatus.active,
              location: _fix(updatedAtMs: DateTime.now().millisecondsSinceEpoch),
            ),
          },
        ),
        cachedRoutes: {
          'patient-1': DirectionsCacheEntry(
            result: _directionsResult(),
            requestedAtMs: 0, // definitely due by time -> triggers a real (failing) refetch
            origin: const LatLng(0, 0), // also due by distance
          ),
        },
      );
      await tester.pumpAndSettle();

      // The stale cached ETA text is still showing — the failed refetch
      // never cleared it.
      expect(find.textContaining('ETA: 12 mins'), findsOneWidget);
    });

    testWidgets('an empty (null) result also keeps the already-cached route', (tester) async {
      when(
        () => directionsService.fetchDirections(origin: any(named: 'origin'), destination: any(named: 'destination')),
      ).thenAnswer((_) async => null);

      await pumpViewer(
        tester,
        patient: _patient(destination: 'Ottawa Civic'),
        hospitals: const [_hospital],
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {
            'patient-1': EmsTrackingInfo(
              status: EmsTrackingStatus.active,
              location: _fix(updatedAtMs: DateTime.now().millisecondsSinceEpoch),
            ),
          },
        ),
        cachedRoutes: {
          'patient-1': DirectionsCacheEntry(result: _directionsResult(), requestedAtMs: 0, origin: const LatLng(0, 0)),
        },
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('ETA: 12 mins'), findsOneWidget);
    });

    testWidgets('a concurrent fetch already in flight is not duplicated', (tester) async {
      var calls = 0;
      final firstFetch = Completer<DirectionsResult?>();
      when(() => directionsService.fetchDirections(origin: any(named: 'origin'), destination: any(named: 'destination'))).thenAnswer((
        _,
      ) {
        calls++;
        return calls == 1 ? firstFetch.future : Future.value(_directionsResult());
      });

      final controller = await pumpViewer(
        tester,
        patient: _patient(destination: 'Ottawa Civic'),
        hospitals: const [_hospital],
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
      );
      await tester.pump();
      expect(calls, 1);

      // A second location update (still due-by-distance, since no route is
      // cached yet) arrives while the first fetch is still pending — must
      // not fire a second overlapping fetch.
      controller.setState(
        EmsLocationState(
          hasLoadedOnce: true,
          info: {
            'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 2000, latitude: 45.42)),
          },
        ),
      );
      await tester.pump();
      expect(calls, 1);

      firstFetch.complete(_directionsResult());
      await tester.pumpAndSettle();
    });
  });

  group('the loading-blur overlay', () {
    testWidgets('shows while a route is expected but not yet cached', (tester) async {
      when(
        () => directionsService.fetchDirections(origin: any(named: 'origin'), destination: any(named: 'destination')),
      ).thenAnswer((_) => Completer<DirectionsResult?>().future);

      await pumpViewer(
        tester,
        patient: _patient(destination: 'Ottawa Civic'),
        hospitals: const [_hospital],
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
      );
      await tester.pump();

      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('never shows once a route is already cached', (tester) async {
      await pumpViewer(
        tester,
        patient: _patient(destination: 'Ottawa Civic'),
        hospitals: const [_hospital],
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
        cachedRoutes: {
          'patient-1': DirectionsCacheEntry(
            result: _directionsResult(),
            requestedAtMs: DateTime.now().millisecondsSinceEpoch,
            origin: const LatLng(45.41, -75.69),
          ),
        },
      );
      await tester.pumpAndSettle();

      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('never shows for a patient with no destination hospital', (tester) async {
      await pumpViewer(
        tester,
        patient: _patient(destination: 'nowhere'),
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(BackdropFilter), findsNothing);
    });
  });

  group('GoogleMapController connection', () {
    testWidgets('connecting sets _mapController, which a later successful fetch then uses to fit the route', (
      tester,
    ) async {
      when(
        () => directionsService.fetchDirections(origin: any(named: 'origin'), destination: any(named: 'destination')),
      ).thenAnswer((_) async => _directionsResult());

      final controller = await pumpViewer(
        tester,
        patient: _patient(destination: 'Ottawa Civic'),
        hospitals: const [_hospital],
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
      );
      await tester.pumpAndSettle();
      // The on-mount fetch above already resolved and cached a route —
      // connect the controller *after*, so the *next* fetch (triggered
      // below) is the one that exercises _mapController?.animateCamera(...)
      // for real, with a genuinely non-null controller behind it.
      await connectGoogleMap(tester, mapPlatform);

      controller.setState(
        EmsLocationState(
          hasLoadedOnce: true,
          info: {
            'patient-1': EmsTrackingInfo(
              status: EmsTrackingStatus.active,
              location: _fix(updatedAtMs: 20000, latitude: 46.0, longitude: -76.0),
            ),
          },
        ),
      );
      await tester.pumpAndSettle();

      // GoogleMapController.animateCamera(...) actually calls
      // animateCameraWithConfiguration under the hood — see the identical
      // note in mock_google_maps.dart.
      verify(
        () => mapPlatform.animateCameraWithConfiguration(any(), any(), mapId: any(named: 'mapId')),
      ).called(greaterThanOrEqualTo(1));
    });

    testWidgets('connecting while a route already exists fits to it immediately', (tester) async {
      await pumpViewer(
        tester,
        patient: _patient(destination: 'Ottawa Civic'),
        hospitals: const [_hospital],
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
        cachedRoutes: {
          'patient-1': DirectionsCacheEntry(
            result: _directionsResult(),
            requestedAtMs: DateTime.now().millisecondsSinceEpoch,
            origin: const LatLng(45.41, -75.69),
          ),
        },
      );
      await tester.pumpAndSettle();

      await connectGoogleMap(tester, mapPlatform);

      // GoogleMapController.animateCamera(...) actually calls
      // animateCameraWithConfiguration under the hood — see the identical
      // note in mock_google_maps.dart.
      verify(
        () => mapPlatform.animateCameraWithConfiguration(any(), any(), mapId: any(named: 'mapId')),
      ).called(greaterThanOrEqualTo(1));
    });
  });

  testWidgets('expanding the map pushes a full-screen route showing the same map', (tester) async {
    await pumpViewer(
      tester,
      patient: _patient(),
      emsState: EmsLocationState(
        hasLoadedOnce: true,
        info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
      ),
    );
    await tester.pumpAndSettle();

    // The map card sits below the fold of this long scrollable page in the
    // default 800x600 test viewport — ensureVisible first, or the tap
    // lands outside the render tree entirely.
    await tester.ensureVisible(find.byTooltip('Expand map'));
    await tester.tap(find.byTooltip('Expand map'));
    await tester.pumpAndSettle();

    expect(find.byType(GoogleMap), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
  });

  group('the expanded (full-screen) map', () {
    // Regression tests for a real bug: expanding used to hand the pushed
    // route a single frozen `GoogleMap` widget instance — built once, at
    // the moment the button was tapped, and never the surrounding card —
    // so it never showed the ETA at all, and never reflected a later
    // position update either. Fixed by making the whole card (map + live-
    // position text + ETA) its own self-contained, independently-reactive
    // widget, so expanding mounts a *second, genuinely live* instance of
    // it instead of reusing a frozen snapshot of just the map.
    testWidgets('shows the ETA/distance text, which the old bare-map expansion never did', (tester) async {
      await pumpViewer(
        tester,
        patient: _patient(destination: _hospital.name),
        hospitals: const [_hospital],
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
        cachedRoutes: {
          'patient-1': DirectionsCacheEntry(result: _directionsResult(), requestedAtMs: 1000, origin: const LatLng(45.41, -75.69)),
        },
      );
      await tester.pumpAndSettle();
      // Confirms the inline card shows it first, same as before.
      expect(find.textContaining('ETA: 12 mins'), findsOneWidget);

      await tester.ensureVisible(find.byTooltip('Expand map'));
      await tester.tap(find.byTooltip('Expand map'));
      await tester.pumpAndSettle();

      expect(find.textContaining('ETA: 12 mins · Distance: 5.2 km to Ottawa Civic'), findsOneWidget);
    });

    testWidgets('keeps updating the live position after a new fix arrives, which the old frozen expansion never did', (
      tester,
    ) async {
      final controller = await pumpViewer(
        tester,
        patient: _patient(),
        emsState: EmsLocationState(
          hasLoadedOnce: true,
          info: {'patient-1': EmsTrackingInfo(status: EmsTrackingStatus.active, location: _fix(updatedAtMs: 1000))},
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byTooltip('Expand map'));
      await tester.tap(find.byTooltip('Expand map'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Live position: 45.4100, -75.6900'), findsOneWidget);

      // A fresh fix with no previous-fix-to-glide-from renders immediately
      // (see the `_onLocationChanged` group above) — no ticker involved, so
      // this is safe to `pumpAndSettle()` through.
      controller.setState(
        EmsLocationState(
          hasLoadedOnce: true,
          info: {
            'patient-1': EmsTrackingInfo(
              status: EmsTrackingStatus.active,
              location: _fix(updatedAtMs: 2000, latitude: 45.5, longitude: -75.5),
            ),
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Live position: 45.5000, -75.5000'), findsOneWidget);
    });
  });
}
