import 'dart:async';
import 'dart:ui';

import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
// intl exports its own TextDirection (for BIDI text, unrelated to
// Flutter/dart:ui's own one) that would otherwise shadow the real one —
// same reasoning as patient_viewer.dart's identical hide clause.
import 'package:intl/intl.dart' hide TextDirection;

import '../services/ambulance_location_service.dart';
import '../utils/geo.dart';

// See patient_viewer.dart's own identical constants for the full
// rationale (raster resolution vs on-screen footprint).
const _markerIconSize = 96.0;
const _markerDisplaySize = 36.0;

// Rendered module-level, not per-widget-instance — mirrors
// patient_viewer.dart's own _vehicleMarkerIcon/_hospitalMarkerIcon
// machinery (including the PaintingBinding.systemFonts re-render fix)
// closely, but duplicated here rather than extracted into a shared
// helper: patient_viewer.dart is a hard-won, fully-covered,
// testability-seam-heavy file, and refactoring it to share this code with
// a brand-new widget adds risk to an already-proven surface for minimal
// reuse benefit. Two variants instead of one: idle (white background,
// matching the single-ambulance icon's look) and transporting
// (AppColors.trackingAccent background, reusing the existing live-
// tracking accent color).
final ValueNotifier<BitmapDescriptor?> _idleAmbulanceIcon = ValueNotifier(null);
final ValueNotifier<BitmapDescriptor?> _transportingAmbulanceIcon = ValueNotifier(null);
bool _markerIconsRequested = false;

/// Idempotent, safe to call from every [_MultipleAmbulanceViewState.initState]
/// — see patient_viewer.dart's `_ensureMarkerIconsRequested` for the full
/// rationale (including the confirmed Flutter Web CanvasKit emoji-font
/// fallback race this also guards against).
void _ensureMarkerIconsRequested() {
  if (_markerIconsRequested) return;
  _markerIconsRequested = true;

  _renderMarkerIcon(_idleAmbulanceIcon, Colors.white);
  _renderMarkerIcon(_transportingAmbulanceIcon, AppColors.trackingAccent);
  PaintingBinding.instance.systemFonts.addListener(_onSystemFontsChanged);
}

void _onSystemFontsChanged() {
  _renderMarkerIcon(_idleAmbulanceIcon, Colors.white);
  _renderMarkerIcon(_transportingAmbulanceIcon, AppColors.trackingAccent);
}

/// Diagnostic only — same rationale/shape as patient_viewer.dart's own
/// debugMarkerRenderCount.
@visibleForTesting
int debugMarkerRenderCount = 0;

void _renderMarkerIcon(ValueNotifier<BitmapDescriptor?> notifier, Color backgroundColor) {
  debugMarkerRenderCount++;
  unawaited(_emojiMarkerBitmap('🚑', backgroundColor).then((icon) => notifier.value = icon));
}

/// See patient_viewer.dart's own resetMarkerIconsForTesting for why this
/// exists (file-lifetime module state that would otherwise leak between
/// tests in this file).
@visibleForTesting
void resetMarkerIconsForTesting() {
  _markerIconsRequested = false;
  PaintingBinding.instance.systemFonts.removeListener(_onSystemFontsChanged);
  debugMarkerRenderCount = 0;
  _idleAmbulanceIcon.value = null;
  _transportingAmbulanceIcon.value = null;
}

/// See patient_viewer.dart's own setMarkerIconsForTesting for why this
/// exists — bypasses the real (async, engine-dependent) rasterization
/// entirely so a test can drive the listener wiring deterministically.
@visibleForTesting
void setMarkerIconsForTesting({BitmapDescriptor? idle, BitmapDescriptor? transporting}) {
  if (idle != null) _idleAmbulanceIcon.value = idle;
  if (transporting != null) _transportingAmbulanceIcon.value = transporting;
}

/// Renders [emoji] centered on a plain circle of [backgroundColor] — same
/// technique and reasoning as patient_viewer.dart's own
/// `_emojiMarkerBitmap`, just parameterized on background color instead of
/// always white, so idle/transporting ambulances render as visibly
/// distinct markers without a third icon.
Future<BitmapDescriptor> _emojiMarkerBitmap(String emoji, Color backgroundColor) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  const radius = _markerIconSize / 2;

  canvas.drawCircle(
    const Offset(radius, radius),
    radius,
    Paint()
      ..color = Colors.black26
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
  );
  canvas.drawCircle(const Offset(radius, radius), radius - 2, Paint()..color = backgroundColor);

  final textPainter = TextPainter(textDirection: TextDirection.ltr)
    ..text = TextSpan(text: emoji, style: const TextStyle(fontSize: _markerIconSize * 0.62))
    ..layout();
  textPainter.paint(
    canvas,
    Offset((_markerIconSize - textPainter.width) / 2, (_markerIconSize - textPainter.height) / 2),
  );

  final image = await recorder.endRecording().toImage(_markerIconSize.toInt(), _markerIconSize.toInt());
  final bytes = await image.toByteData(format: ImageByteFormat.png);
  return BitmapDescriptor.bytes(bytes!.buffer.asUint8List(), width: _markerDisplaySize, height: _markerDisplaySize);
}

/// Which ambulances to show — backs the physician app filter's two new
/// options ("View All Ambulances" / "View All Transporting Ambulances").
enum AmbulanceViewFilter { all, transportingOnly }

/// The fleet-wide map, rendered in place of the patient list/viewer when
/// [MainViewScreen]'s new view-mode control is set to either ambulance
/// filter. Structurally mirrors patient_viewer.dart's `_LiveMapCard` (the
/// same marker-icon listener wiring, the same camera-fit-on-connect race
/// handling), but every ambulance's marker at once instead of one vehicle
/// — so there's no per-marker glide animation (see
/// `ActiveAmbulanceLocation`'s own doc comment on why) and the camera fits
/// to the *whole fleet's* bounds once, rather than following a single
/// vehicle.
class MultipleAmbulanceView extends ConsumerStatefulWidget {
  const MultipleAmbulanceView({required this.filter, super.key});

  final AmbulanceViewFilter filter;

  @override
  ConsumerState<MultipleAmbulanceView> createState() => _MultipleAmbulanceViewState();
}

class _MultipleAmbulanceViewState extends ConsumerState<MultipleAmbulanceView> {
  GoogleMapController? _mapController;
  BitmapDescriptor? _idleIcon;
  BitmapDescriptor? _transportingIcon;

  // Fits the camera to the fleet's bounds once — after that, the physician
  // may have panned/zoomed manually, so later rebuilds (a fresh Firestore
  // snapshot, a staleness sweep) don't keep yanking the view back.
  bool _hasAutoFit = false;

  @override
  void initState() {
    super.initState();
    _ensureMarkerIconsRequested();
    _idleIcon = _idleAmbulanceIcon.value;
    _transportingIcon = _transportingAmbulanceIcon.value;
    _idleAmbulanceIcon.addListener(_onIdleIconChanged);
    _transportingAmbulanceIcon.addListener(_onTransportingIconChanged);
  }

  void _onIdleIconChanged() {
    if (mounted) setState(() => _idleIcon = _idleAmbulanceIcon.value);
  }

  void _onTransportingIconChanged() {
    if (mounted) setState(() => _transportingIcon = _transportingAmbulanceIcon.value);
  }

  @override
  void dispose() {
    _idleAmbulanceIcon.removeListener(_onIdleIconChanged);
    _transportingAmbulanceIcon.removeListener(_onTransportingIconChanged);
    super.dispose();
  }

  void _fitToPoints(List<LatLng> points) {
    if (_hasAutoFit) return;
    final controller = _mapController;
    if (controller == null || points.isEmpty) return;
    _hasAutoFit = true;
    if (points.length == 1) {
      controller.animateCamera(CameraUpdate.newLatLngZoom(points.first, 15));
    } else {
      controller.animateCamera(CameraUpdate.newLatLngBounds(boundsFromPoints(points), 40));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ambulanceLocationProvider);

    if (!state.hasLoadedOnce) {
      return const Center(child: CircularProgressIndicator());
    }

    final entries = state.info.values
        .where((info) => widget.filter == AmbulanceViewFilter.all || info.location.isTransporting)
        .toList();

    if (entries.isEmpty) {
      return EmptyState(
        graphic: EmptyStateGraphic.chartPulse,
        title: widget.filter == AmbulanceViewFilter.transportingOnly
            ? 'No ambulances are currently transporting'
            : 'No ambulances to show',
        subtitle: 'Ambulance locations appear here once a crew signs in and identifies their vehicle.',
        centered: true,
      );
    }

    final points = [for (final entry in entries) LatLng(entry.location.latitude, entry.location.longitude)];
    _fitToPoints(points);

    final markers = {
      for (final entry in entries)
        Marker(
          markerId: MarkerId(entry.location.ambulanceId),
          position: LatLng(entry.location.latitude, entry.location.longitude),
          icon: (entry.location.isTransporting ? _transportingIcon : _idleIcon) ??
              BitmapDescriptor.defaultMarkerWithHue(
                entry.location.isTransporting ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueRed,
              ),
          infoWindow: InfoWindow(
            title: entry.location.ambulanceId,
            snippet: entry.status == AmbulanceStatus.stale
                ? 'Last updated at ${DateFormat('h:mm:ss a').format(DateTime.fromMillisecondsSinceEpoch(entry.location.updatedAtMs))}'
                : entry.location.isTransporting
                ? 'Transporting a patient'
                : 'Idle',
          ),
        ),
    };

    return GoogleMap(
      initialCameraPosition: CameraPosition(target: points.first, zoom: 12),
      onMapCreated: (controller) {
        _mapController = controller;
        _fitToPoints(points);
      },
      markers: markers,
    );
  }
}
