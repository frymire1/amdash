import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:physician/classes/active_ambulance_location.dart';
import 'package:physician/services/ambulance_highlight_service.dart';
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
  String phoneNumber = '',
}) {
  return AmbulanceTrackingInfo(
    status: status,
    location: ActiveAmbulanceLocation(
      ambulanceId: ambulanceId,
      latitude: latitude,
      longitude: longitude,
      isTransporting: isTransporting,
      updatedAtMs: updatedAtMs,
      phoneNumber: phoneNumber,
    ),
  );
}

void main() {
  setUpAll(() {
    registerGoogleMapsFallbackValues();
    registerFallbackValue(const MarkerId(''));
  });

  late MockGoogleMapsFlutterPlatform mapPlatform;

  setUp(() {
    mapPlatform = installMockGoogleMaps();
    // Every test below can select/hover an ambulance (which always
    // touches _syncInfoWindow too, regardless of what it's testing) —
    // stubbed globally rather than per-test so a test focused on camera
    // behavior doesn't also need to know about the info-window channel.
    when(() => mapPlatform.showMarkerInfoWindow(any(), mapId: any(named: 'mapId'))).thenAnswer((_) async {});
    when(() => mapPlatform.hideMarkerInfoWindow(any(), mapId: any(named: 'mapId'))).thenAnswer((_) async {});
  });

  // Returns both the fake location controller and the widget tree's own
  // ProviderContainer (via ProviderScope.containerOf, same pattern
  // main_view_screen_test.dart's own pumpScreen uses) — the highlight
  // tests below need the container to read/seed ambulanceHighlightProvider
  // directly, not just the location controller.
  Future<(_FakeAmbulanceLocationController, ProviderContainer)> pumpView(
    WidgetTester tester, {
    AmbulanceViewFilter filter = AmbulanceViewFilter.all,
    AmbulanceLocationState state = const AmbulanceLocationState(hasLoadedOnce: true),
  }) async {
    final controller = _FakeAmbulanceLocationController(state);
    late ProviderContainer container;
    await pumpApp(
      tester,
      Builder(
        builder: (context) {
          container = ProviderScope.containerOf(context);
          return MultipleAmbulanceView(filter: filter);
        },
      ),
      overrides: [ambulanceLocationProvider.overrideWith(() => controller)],
    );
    return (controller, container);
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

    testWidgets('emptyOnly filter shows its own empty-state copy when nothing is empty', (
      tester,
    ) async {
      await pumpView(
        tester,
        filter: AmbulanceViewFilter.emptyOnly,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5', isTransporting: true)}),
      );
      await tester.pumpAndSettle();

      expect(find.text('No empty ambulances right now'), findsOneWidget);
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

    testWidgets('emptyOnly hides transporting ambulances', (tester) async {
      await pumpView(
        tester,
        filter: AmbulanceViewFilter.emptyOnly,
        state: AmbulanceLocationState(
          hasLoadedOnce: true,
          info: {'Unit 5': _info('Unit 5'), 'Unit 9': _info('Unit 9', isTransporting: true)},
        ),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.markers.map((m) => m.markerId.value), ['Unit 5']);
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
    testWidgets('an active empty ambulance shows "Empty"', (tester) async {
      await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      final marker = map.markers.first;
      expect(marker.infoWindow.title, 'Unit 5');
      expect(marker.infoWindow.snippet, 'Empty');
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

    testWidgets('a phone number shows on its own line above the status text', (tester) async {
      await pumpView(
        tester,
        state: AmbulanceLocationState(
          hasLoadedOnce: true,
          info: {'Unit 5': _info('Unit 5', phoneNumber: '555-0123')},
        ),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      // Native (this is a `flutter test` run, not web — kIsWeb is a
      // compile-time constant, always false here) uses a plain '\n'.
      expect(map.markers.first.infoWindow.snippet, '555-0123\nEmpty');
    });

    testWidgets('no phone number on record falls back to just the status text, unchanged', (tester) async {
      await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.markers.first.infoWindow.snippet, 'Empty');
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
      final (controller, _) = await pumpView(
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

  group('highlighting (ambulanceHighlightProvider sync)', () {
    testWidgets('tapping a marker selects it — the reverse (marker hover) is not implemented, see this '
        "widget's own doc comment on why", (tester) async {
      final (_, container) = await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      map.markers.first.onTap!();

      expect(container.read(ambulanceHighlightProvider).selectedId, 'Unit 5');
    });

    testWidgets('the highlighted marker stays fully opaque and is raised to the front; others are dimmed', (
      tester,
    ) async {
      final (_, container) = await pumpView(
        tester,
        state: AmbulanceLocationState(
          hasLoadedOnce: true,
          info: {'Unit 5': _info('Unit 5'), 'Unit 9': _info('Unit 9', latitude: 46, longitude: -76)},
        ),
      );
      await tester.pumpAndSettle();

      container.read(ambulanceHighlightProvider.notifier).select('Unit 5');
      await tester.pump();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      final highlighted = map.markers.firstWhere((m) => m.markerId.value == 'Unit 5');
      final dimmed = map.markers.firstWhere((m) => m.markerId.value == 'Unit 9');
      expect(highlighted.alpha, 1.0);
      expect(highlighted.zIndexInt, greaterThan(dimmed.zIndexInt));
      expect(dimmed.alpha, lessThan(1.0));
    });

    testWidgets('nothing highlighted leaves every marker fully opaque', (tester) async {
      await pumpView(
        tester,
        state: AmbulanceLocationState(
          hasLoadedOnce: true,
          info: {'Unit 5': _info('Unit 5'), 'Unit 9': _info('Unit 9', latitude: 46, longitude: -76)},
        ),
      );
      await tester.pumpAndSettle();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.markers.every((m) => m.alpha == 1.0), true);
    });

    testWidgets('a highlight change shows the new marker\'s info window and hides the previous one', (
      tester,
    ) async {
      when(
        () => mapPlatform.showMarkerInfoWindow(any(), mapId: any(named: 'mapId')),
      ).thenAnswer((_) async {});
      when(
        () => mapPlatform.hideMarkerInfoWindow(any(), mapId: any(named: 'mapId')),
      ).thenAnswer((_) async {});

      final (_, container) = await pumpView(
        tester,
        state: AmbulanceLocationState(
          hasLoadedOnce: true,
          info: {'Unit 5': _info('Unit 5'), 'Unit 9': _info('Unit 9', latitude: 46, longitude: -76)},
        ),
      );
      await tester.pumpAndSettle();
      await connectGoogleMap(tester, mapPlatform);

      final notifier = container.read(ambulanceHighlightProvider.notifier);
      notifier.select('Unit 5');
      await tester.pump();
      verify(
        () => mapPlatform.showMarkerInfoWindow(const MarkerId('Unit 5'), mapId: any(named: 'mapId')),
      ).called(1);

      notifier.select('Unit 9');
      await tester.pump();
      verify(
        () => mapPlatform.hideMarkerInfoWindow(const MarkerId('Unit 5'), mapId: any(named: 'mapId')),
      ).called(1);
      verify(
        () => mapPlatform.showMarkerInfoWindow(const MarkerId('Unit 9'), mapId: any(named: 'mapId')),
      ).called(1);
    });

    testWidgets('re-selecting the same ambulance does not re-touch the info-window platform channel', (
      tester,
    ) async {
      when(
        () => mapPlatform.showMarkerInfoWindow(any(), mapId: any(named: 'mapId')),
      ).thenAnswer((_) async {});

      final (_, container) = await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      await tester.pumpAndSettle();
      await connectGoogleMap(tester, mapPlatform);

      final notifier = container.read(ambulanceHighlightProvider.notifier);
      notifier.select('Unit 5');
      await tester.pump();
      notifier.hover('Unit 5');
      await tester.pump();

      verify(
        () => mapPlatform.showMarkerInfoWindow(const MarkerId('Unit 5'), mapId: any(named: 'mapId')),
      ).called(1);
    });
  });

  group('camera focus on selection', () {
    testWidgets('selecting an ambulance zooms the map to it, at a tighter zoom than the fleet fit', (
      tester,
    ) async {
      final (_, container) = await pumpView(
        tester,
        state: AmbulanceLocationState(
          hasLoadedOnce: true,
          info: {'Unit 5': _info('Unit 5'), 'Unit 9': _info('Unit 9', latitude: 46, longitude: -76)},
        ),
      );
      await tester.pumpAndSettle();
      await connectGoogleMap(tester, mapPlatform);
      clearInteractions(mapPlatform);

      container.read(ambulanceHighlightProvider.notifier).select('Unit 9');
      await tester.pump();

      final captured = verify(
        () => mapPlatform.animateCameraWithConfiguration(captureAny(), any(), mapId: any(named: 'mapId')),
      ).captured;
      expect(
        captured.map((call) => (call as CameraUpdate).toJson()),
        // contains() on an Iterable checks membership via `==`, which
        // Dart's built-in List doesn't override for structural equality —
        // anyElement(equals(...)) is what actually performs a deep
        // (recursive) comparison against the nested [lat, lng] list.
        anyElement(equals(['newLatLngZoom', [46.0, -76.0], 16.0])),
      );
    });

    testWidgets('hovering alone does not move the camera — only a genuine selection does', (tester) async {
      final (_, container) = await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      await tester.pumpAndSettle();
      await connectGoogleMap(tester, mapPlatform);
      clearInteractions(mapPlatform);

      container.read(ambulanceHighlightProvider.notifier).hover('Unit 5');
      await tester.pump();

      verifyNever(() => mapPlatform.animateCameraWithConfiguration(any(), any(), mapId: any(named: 'mapId')));
    });

    testWidgets('selecting before the map controller connects is a no-op, not a crash', (tester) async {
      final (_, container) = await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      await tester.pumpAndSettle();

      container.read(ambulanceHighlightProvider.notifier).select('Unit 5');
      await tester.pump();
      // No exception — _mapController is still null at this point, and
      // _focusOnAmbulance no-ops rather than crashing on it.
    });

    testWidgets('selecting an ambulance absent from the current snapshot is a no-op', (tester) async {
      final (_, container) = await pumpView(
        tester,
        state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      await tester.pumpAndSettle();
      await connectGoogleMap(tester, mapPlatform);
      clearInteractions(mapPlatform);

      container.read(ambulanceHighlightProvider.notifier).select('Unit 9');
      await tester.pump();

      verifyNever(() => mapPlatform.animateCameraWithConfiguration(any(), any(), mapId: any(named: 'mapId')));
    });

    testWidgets('an already-selected ambulance is focused immediately once the map reconnects', (tester) async {
      // Simulates MainViewScreen disposing/recreating this widget when
      // toggling between the mobile list and map views — the selection
      // lives in ambulanceHighlightProvider, outside this widget's own
      // lifecycle, so it can already be set before this instance (and its
      // own ref.listen) ever exists. Selecting on the container directly,
      // before pumping the widget at all, reproduces that ordering.
      final controller = _FakeAmbulanceLocationController(
        AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
      );
      final container = ProviderContainer(overrides: [ambulanceLocationProvider.overrideWith(() => controller)]);
      addTearDown(container.dispose);
      container.read(ambulanceHighlightProvider.notifier).select('Unit 5');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: MultipleAmbulanceView(filter: AmbulanceViewFilter.all))),
        ),
      );
      await tester.pumpAndSettle();
      await connectGoogleMap(tester, mapPlatform);

      final captured = verify(
        () => mapPlatform.animateCameraWithConfiguration(captureAny(), any(), mapId: any(named: 'mapId')),
      ).captured;
      expect(
        captured.map((call) => (call as CameraUpdate).toJson()),
        anyElement(equals(['newLatLngZoom', [45.4, -75.7], 16.0])),
      );
    });
  });
}
