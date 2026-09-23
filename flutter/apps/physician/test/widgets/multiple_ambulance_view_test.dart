import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:physician/classes/active_ambulance_location.dart';
import 'package:physician/services/ambulance_location_service.dart';
import 'package:physician/widgets/multiple_ambulance_view.dart';

import '../support/mock_google_maps.dart';
import '../support/pump_app.dart';

// Same minimal-fake rationale as patient_viewer_test.dart's own
// _FakeEmsLocationController — AmbulanceLocationController does genuine
// Firestore work in build(), which a plain `flutter test` has no backing
// for.
class _FakeAmbulanceLocationController extends AmbulanceLocationController {
  _FakeAmbulanceLocationController(this._initial);
  final AmbulanceLocationState _initial;

  @override
  AmbulanceLocationState build() => _initial;

  void setState(AmbulanceLocationState next) => state = next;
}

AmbulanceTrackingInfo _info(
  String ambulanceId, {
  double latitude = 45.4,
  double longitude = -75.7,
  bool isTransporting = false,
  AmbulanceStatus status = AmbulanceStatus.active,
  int updatedAtMs = 1000,
}) {
  return AmbulanceTrackingInfo(
    status: status,
    location: ActiveAmbulanceLocation(
      ambulanceId: ambulanceId,
      latitude: latitude,
      longitude: longitude,
      isTransporting: isTransporting,
      updatedAtMs: updatedAtMs,
    ),
  );
}

void main() {
  setUpAll(() {
    registerGoogleMapsFallbackValues();
  });

  late MockGoogleMapsFlutterPlatform mapPlatform;

  setUp(() {
    mapPlatform = installMockGoogleMaps();
  });

  Future<_FakeAmbulanceLocationController> pumpView(
    WidgetTester tester, {
    AmbulanceViewFilter filter = AmbulanceViewFilter.all,
    AmbulanceLocationState state = const AmbulanceLocationState(hasLoadedOnce: true),
  }) async {
    final controller = _FakeAmbulanceLocationController(state);
    await pumpApp(
      tester,
      MultipleAmbulanceView(filter: filter),
      overrides: [ambulanceLocationProvider.overrideWith(() => controller)],
    );
    return controller;
  }

  group('loading', () {
    testWidgets('shows a spinner before the first snapshot arrives', (tester) async {
      await pumpView(tester, state: const AmbulanceLocationState());
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(GoogleMap), findsNothing);
    });
  });

  group('empty state', () {
    testWidgets('shows once loaded with no ambulances at all', (tester) async {
      await pumpView(tester);
      await tester.pumpAndSettle();

      expect(find.text('No ambulances to show'), findsOneWidget);
      expect(find.byType(GoogleMap), findsNothing);
    });

    testWidgets('transportingOnly filter shows its own empty-state copy when nothing is transporting', (
      tester,
    ) async {
      await pumpView(
        tester,
        filter: AmbulanceViewFilter.transportingOnly,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      await tester.pumpAndSettle();

      expect(find.text('No ambulances are currently transporting'), findsOneWidget);
    });
  });

  group('filter', () {
    testWidgets('all shows every known ambulance regardless of isTransporting', (tester) async {
      await pumpView(
        tester,
        state: AmbulanceLocationState(
          hasLoadedOnce: true,
          info: {'Unit 5': _info('Unit 5'), 'Unit 9': _info('Unit 9', isTransporting: true)},
        ),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.markers.map((m) => m.markerId.value), containsAll(['Unit 5', 'Unit 9']));
    });

    testWidgets('transportingOnly hides idle ambulances', (tester) async {
      await pumpView(
        tester,
        filter: AmbulanceViewFilter.transportingOnly,
        state: AmbulanceLocationState(
          hasLoadedOnce: true,
          info: {'Unit 5': _info('Unit 5'), 'Unit 9': _info('Unit 9', isTransporting: true)},
        ),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.markers.map((m) => m.markerId.value), ['Unit 9']);
    });

    testWidgets('a stale ambulance still shows (not hidden), same as a patient staying visible', (tester) async {
      await pumpView(
        tester,
        state: AmbulanceLocationState(
          hasLoadedOnce: true,
          info: {'Unit 5': _info('Unit 5', status: AmbulanceStatus.stale)},
        ),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.markers.length, 1);
    });
  });

  group('marker info window', () {
    testWidgets('an active idle ambulance shows "Idle"', (tester) async {
      await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      final marker = map.markers.first;
      expect(marker.infoWindow.title, 'Unit 5');
      expect(marker.infoWindow.snippet, 'Idle');
    });

    testWidgets('an active transporting ambulance shows "Transporting a patient"', (tester) async {
      await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5', isTransporting: true)}),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.markers.first.infoWindow.snippet, 'Transporting a patient');
    });

    testWidgets('a stale ambulance shows the last-updated-at time instead', (tester) async {
      await pumpView(
        tester,
        state: AmbulanceLocationState(
          hasLoadedOnce: true,
          info: {'Unit 5': _info('Unit 5', status: AmbulanceStatus.stale)},
        ),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.markers.first.infoWindow.snippet, startsWith('Last updated at'));
    });
  });

  group('marker icons', () {
    testWidgets('an icon resolving after mount updates an already-open map, via the listener wiring', (
      tester,
    ) async {
      // See patient_viewer_test.dart's identical test for the full
      // rationale — same listener-wiring proof, just for the idle/
      // transporting icon pair instead of vehicle/hospital.
      resetMarkerIconsForTesting();

      await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5', isTransporting: true)}),
      );
      await tester.pumpAndSettle();

      final testIdleIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
      final testTransportingIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueYellow);
      setMarkerIconsForTesting(idle: testIdleIcon, transporting: testTransportingIcon);
      await tester.pump();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.markers.first.icon, equals(testTransportingIcon));
    });

    testWidgets('a systemFonts change re-renders both icons', (tester) async {
      resetMarkerIconsForTesting();

      await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      await tester.pumpAndSettle();

      final countAfterMount = debugMarkerRenderCount;

      final message = const JSONMessageCodec().encodeMessage(<String, dynamic>{'type': 'fontsChange'});
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/system',
        message,
        (_) {},
      );
      await tester.pump();

      expect(
        debugMarkerRenderCount,
        countAfterMount + 2,
        reason: 'a systemFonts change should re-render both the idle and transporting icons again',
      );
    });
  });

  group('camera fit', () {
    testWidgets('a single ambulance fits with newLatLngZoom once the controller connects', (tester) async {
      await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      await tester.pumpAndSettle();

      await connectGoogleMap(tester, mapPlatform);

      // GoogleMapController.animateCamera(...) actually calls
      // animateCameraWithConfiguration under the hood — see
      // mock_google_maps.dart's own note.
      verify(
        () => mapPlatform.animateCameraWithConfiguration(any(), any(), mapId: any(named: 'mapId')),
      ).called(greaterThanOrEqualTo(1));
    });

    testWidgets('two or more ambulances fit with newLatLngBounds once the controller connects', (tester) async {
      await pumpView(
        tester,
        state: AmbulanceLocationState(
          hasLoadedOnce: true,
          info: {'Unit 5': _info('Unit 5'), 'Unit 9': _info('Unit 9', latitude: 46, longitude: -76)},
        ),
      );
      await tester.pumpAndSettle();

      await connectGoogleMap(tester, mapPlatform);

      verify(
        () => mapPlatform.animateCameraWithConfiguration(any(), any(), mapId: any(named: 'mapId')),
      ).called(greaterThanOrEqualTo(1));
    });

    testWidgets('only fits once — a later snapshot does not yank the camera again', (tester) async {
      final controller = await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      await tester.pumpAndSettle();
      await connectGoogleMap(tester, mapPlatform);
      clearInteractions(mapPlatform);

      controller.setState(
        AmbulanceLocationState(
          hasLoadedOnce: true,
          info: {'Unit 5': _info('Unit 5', latitude: 50, longitude: -80)},
        ),
      );
      await tester.pumpAndSettle();

      verifyNever(() => mapPlatform.animateCameraWithConfiguration(any(), any(), mapId: any(named: 'mapId')));
    });
  });
}
