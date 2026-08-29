import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:mocktail/mocktail.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// The key of the placeholder [SizedBox] [installMockGoogleMaps] returns in
/// place of a real native map view.
const mockGoogleMapKey = Key('mock_google_map');

class MockGoogleMapsFlutterPlatform extends Mock
    with MockPlatformInterfaceMixin
    implements GoogleMapsFlutterPlatform {}

/// Registers the mocktail fallback values [installMockGoogleMaps]/
/// [connectGoogleMap] need for their `any()`/`captureAny()` matchers — call
/// once from a top-level `setUpAll`.
void registerGoogleMapsFallbackValues() {
  registerFallbackValue(
    const MapWidgetConfiguration(
      initialCameraPosition: CameraPosition(target: LatLng(0, 0)),
      textDirection: TextDirection.ltr,
    ),
  );
  registerFallbackValue(const MapConfiguration());
  registerFallbackValue(const MapObjects());
  registerFallbackValue(MarkerUpdates.from(const <Marker>{}, const <Marker>{}));
  registerFallbackValue(PolygonUpdates.from(const <Polygon>{}, const <Polygon>{}));
  registerFallbackValue(PolylineUpdates.from(const <Polyline>{}, const <Polyline>{}));
  registerFallbackValue(CircleUpdates.from(const <Circle>{}, const <Circle>{}));
  registerFallbackValue(HeatmapUpdates.from(const <Heatmap>{}, const <Heatmap>{}));
  registerFallbackValue(ClusterManagerUpdates.from(const <ClusterManager>{}, const <ClusterManager>{}));
  registerFallbackValue(GroundOverlayUpdates.from(const <GroundOverlay>{}, const <GroundOverlay>{}));
  registerFallbackValue(CameraUpdate.newLatLngZoom(const LatLng(0, 0), 1));
  registerFallbackValue(const CameraUpdateAnimationConfiguration());
}

/// Installs a mocked [GoogleMapsFlutterPlatform] for the duration of one
/// test (auto-restored via [addTearDown]) — same `PlatformInterface`/
/// `MockPlatformInterfaceMixin` technique already used for `UrlLauncherPlatform`/
/// `GeolocatorPlatform` elsewhere in this repo, confirmed via a throwaway
/// probe test (see git history) that `GoogleMap` calls
/// `GoogleMapsFlutterPlatform.instance.buildViewWithConfiguration(...)` to
/// render itself.
///
/// Stubs just enough (`buildViewWithConfiguration` -> a keyed placeholder,
/// [mockGoogleMapKey]) for `GoogleMap` to pump without a real platform view
/// — sufficient for most widget tests (`patient_viewer.dart`'s own marker/
/// polyline/glide-ticker logic never depends on a connected controller;
/// `_mapController?.foo(...)` is null-safe everywhere it's used). Only a
/// test that specifically needs a connected `GoogleMapController` (e.g. the
/// "controller connects after a route already arrived" race) should also
/// call [connectGoogleMap].
MockGoogleMapsFlutterPlatform installMockGoogleMaps() {
  final mock = MockGoogleMapsFlutterPlatform();
  final real = GoogleMapsFlutterPlatform.instance;
  GoogleMapsFlutterPlatform.instance = mock;
  addTearDown(() => GoogleMapsFlutterPlatform.instance = real);

  when(
    () => mock.buildViewWithConfiguration(
      any(),
      any(),
      widgetConfiguration: any(named: 'widgetConfiguration'),
      mapObjects: any(named: 'mapObjects'),
      mapConfiguration: any(named: 'mapConfiguration'),
    ),
  ).thenReturn(const SizedBox(key: mockGoogleMapKey));

  return mock;
}

/// Simulates a real platform view finishing initialization and delivering
/// its `onPlatformViewCreated` callback, so `GoogleMap.onMapCreated` fires
/// with a real (platform-mocked) `GoogleMapController` — **confirmed via a
/// throwaway probe test that this never happens just from pumping**: unlike
/// a real device, nothing fires that callback on its own against a mocked
/// platform, since it's normally delivered async by the native platform
/// view via a platform-channel event with no test-visible trigger.
///
/// `GoogleMapController.init()`/`._connectStreams()` unconditionally
/// subscribes to 11 event streams and fires off 8 unawaited `update*()`
/// calls right after connecting (confirmed via `controller.dart` source) —
/// every one needs a stub or an unstubbed `Mock`'s `null` default blows up
/// against its non-nullable `Stream`/`Future` return type, so this stubs
/// all of them before invoking the captured callback.
Future<void> connectGoogleMap(WidgetTester tester, MockGoogleMapsFlutterPlatform mock) async {
  when(() => mock.init(any())).thenAnswer((_) async {});
  when(() => mock.onMarkerTap(mapId: any(named: 'mapId'))).thenAnswer((_) => const Stream.empty());
  when(() => mock.onMarkerDragStart(mapId: any(named: 'mapId'))).thenAnswer((_) => const Stream.empty());
  when(() => mock.onMarkerDrag(mapId: any(named: 'mapId'))).thenAnswer((_) => const Stream.empty());
  when(() => mock.onMarkerDragEnd(mapId: any(named: 'mapId'))).thenAnswer((_) => const Stream.empty());
  when(() => mock.onInfoWindowTap(mapId: any(named: 'mapId'))).thenAnswer((_) => const Stream.empty());
  when(() => mock.onPolylineTap(mapId: any(named: 'mapId'))).thenAnswer((_) => const Stream.empty());
  when(() => mock.onPolygonTap(mapId: any(named: 'mapId'))).thenAnswer((_) => const Stream.empty());
  when(() => mock.onCircleTap(mapId: any(named: 'mapId'))).thenAnswer((_) => const Stream.empty());
  when(() => mock.onTap(mapId: any(named: 'mapId'))).thenAnswer((_) => const Stream.empty());
  when(() => mock.onLongPress(mapId: any(named: 'mapId'))).thenAnswer((_) => const Stream.empty());
  when(() => mock.onClusterTap(mapId: any(named: 'mapId'))).thenAnswer((_) => const Stream.empty());
  when(() => mock.updateMarkers(any(), mapId: any(named: 'mapId'))).thenAnswer((_) async {});
  when(() => mock.updatePolygons(any(), mapId: any(named: 'mapId'))).thenAnswer((_) async {});
  when(() => mock.updatePolylines(any(), mapId: any(named: 'mapId'))).thenAnswer((_) async {});
  when(() => mock.updateCircles(any(), mapId: any(named: 'mapId'))).thenAnswer((_) async {});
  when(() => mock.updateHeatmaps(any(), mapId: any(named: 'mapId'))).thenAnswer((_) async {});
  when(
    () => mock.updateTileOverlays(newTileOverlays: any(named: 'newTileOverlays'), mapId: any(named: 'mapId')),
  ).thenAnswer((_) async {});
  when(() => mock.updateClusterManagers(any(), mapId: any(named: 'mapId'))).thenAnswer((_) async {});
  when(() => mock.updateGroundOverlays(any(), mapId: any(named: 'mapId'))).thenAnswer((_) async {});
  when(() => mock.animateCamera(any(), mapId: any(named: 'mapId'))).thenAnswer((_) async {});
  // GoogleMapController.animateCamera(...) actually calls
  // animateCameraWithConfiguration (its own default impl just delegates to
  // animateCamera, but the controller calls this one directly) —
  // confirmed via a real test failure ("type 'Null' is not a subtype of
  // type 'Future<void>'") that stubbing animateCamera alone isn't enough.
  when(
    () => mock.animateCameraWithConfiguration(any(), any(), mapId: any(named: 'mapId')),
  ).thenAnswer((_) async {});

  // captureAny() records args from every call made so far, flattened
  // pairwise (creationId, callback, creationId, callback, ...) — take the
  // most recent pair, in case the widget already rebuilt (and thus called
  // buildViewWithConfiguration) more than once before this runs.
  final captured = verify(
    () => mock.buildViewWithConfiguration(
      captureAny(),
      captureAny(),
      widgetConfiguration: any(named: 'widgetConfiguration'),
      mapObjects: any(named: 'mapObjects'),
      mapConfiguration: any(named: 'mapConfiguration'),
    ),
  ).captured;
  final creationId = captured[captured.length - 2] as int;
  final onPlatformViewCreated = captured.last as Future<void> Function(int);
  await onPlatformViewCreated(creationId);
  await tester.pump();
}
