import 'dart:async';
import 'dart:ui';

import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
// intl exports its own TextDirection (for BIDI text, unrelated to
// Flutter/dart:ui's own one) that would otherwise shadow the real one —
// same reasoning as patient_viewer.dart's identical hide clause.
import 'package:intl/intl.dart' hide TextDirection;

import '../services/ambulance_highlight_service.dart';
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
/// options ("View All Ambulances" / "View All Empty Ambulances").
enum AmbulanceViewFilter { all, emptyOnly }

// google_maps_flutter_web renders InfoWindow.snippet through
// sanitizeHtml() + innerHTML (confirmed against its installed
// convert.dart), not as plain text — a bare '\n' is just whitespace in a
// text node and collapses to a space there (default CSS
// white-space: normal). '<br>' is on sanitize_html's element allowlist,
// so it survives there and renders as a real line break — but native
// Android/iOS pass the snippet straight to the platform SDK's own
// plain-text snippet renderer with no HTML interpretation at all, where
// '\n' is what actually produces a break and a literal '<br>' would
// render as text. kIsWeb is a compile-time constant, always false under
// `flutter test` (Dart VM, not a web build) — see
// ems_tracking_service.dart's identical note — so the web half of this
// line is unreachable there, same as directions_service.dart's own
// `??` fallback.
final _infoWindowLineBreak = kIsWeb ? '<br>' : '\n'; // coverage:ignore-line

String _infoWindowSnippet(AmbulanceTrackingInfo entry) {
  final statusText = entry.status == AmbulanceStatus.stale
      ? 'Last updated at ${DateFormat('h:mm:ss a').format(DateTime.fromMillisecondsSinceEpoch(entry.location.updatedAtMs))}'
      : entry.location.isTransporting
      ? 'Transporting a patient'
      : 'Empty';
  final phoneNumber = entry.location.phoneNumber;
  return phoneNumber.isEmpty ? statusText : '$phoneNumber$_infoWindowLineBreak$statusText';
}

/// The fleet-wide map, rendered alongside [AmbulanceList] (its sidebar
/// counterpart) when [MainViewScreen]'s view-mode control is set to either
/// ambulance filter. Structurally mirrors patient_viewer.dart's
/// `_LiveMapCard` (the same marker-icon listener wiring, the same
/// camera-fit-on-connect race handling), but every ambulance's marker at
/// once instead of one vehicle — so there's no per-marker glide animation
/// (see `ActiveAmbulanceLocation`'s own doc comment on why) and the camera
/// fits to the *whole fleet's* bounds once, rather than following a single
/// vehicle.
///
/// Synchronizes with [AmbulanceList] via `ambulanceHighlightProvider`:
/// tapping a marker here selects it (matching a tap/click on its sidebar
/// card); tapping/hovering a sidebar card dims every other marker and
/// raises the matching one to the front, with its info window opened
/// programmatically. The reverse — hovering a *marker* highlighting its
/// card — isn't implemented, because it isn't implementable: `Marker`
/// (google_maps_flutter_platform_interface's own type) exposes `onTap`,
/// `onDrag`/`onDragStart`/`onDragEnd`, and nothing else — no `onHover` at
/// all, on any platform this plugin supports (confirmed against its
/// source, not just its docs). A marker can only ever drive `select`,
/// never `hover`.
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

  // Which marker's info window is currently open on the real map — tracked
  // separately from ambulanceHighlightProvider's own state so a highlight
  // change only ever touches the platform channel for the two markers that
  // actually need it (hide the old one, show the new one), not every
  // marker on every highlight change.
  String? _openInfoWindowId;

  void _syncInfoWindow(String? highlightedId) {
    final controller = _mapController;
    if (controller == null || highlightedId == _openInfoWindowId) return;
    if (_openInfoWindowId != null) {
      unawaited(controller.hideMarkerInfoWindow(MarkerId(_openInfoWindowId!)));
    }
    if (highlightedId != null) {
      unawaited(controller.showMarkerInfoWindow(MarkerId(highlightedId)));
    }
    _openInfoWindowId = highlightedId;
  }

  // Only ever called for a genuine selection (a card tap or a marker tap),
  // never a hover — see the ref.listen call below, which gates this on
  // selectedId actually changing, not effectiveId (hover would fire this
  // on every mouse-over otherwise). Reads the ambulance's position fresh
  // via ref.read rather than a closed-over build()-time value, since this
  // runs from a listener callback that can fire between builds.
  void _focusOnAmbulance(String ambulanceId) {
    final controller = _mapController;
    final location = ref.read(ambulanceLocationProvider).info[ambulanceId]?.location;
    if (controller == null || location == null) return;
    unawaited(
      controller.animateCamera(CameraUpdate.newLatLngZoom(LatLng(location.latitude, location.longitude), 16)),
    );
  }

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
    final highlightedId = ref.watch(ambulanceHighlightProvider).effectiveId;
    // Called unconditionally, ahead of every early return below — a
    // ref.listen skipped on some builds (e.g. while state.hasLoadedOnce is
    // still false) but not others isn't a supported Riverpod pattern.
    ref.listen<AmbulanceHighlightState>(ambulanceHighlightProvider, (previous, next) {
      _syncInfoWindow(next.effectiveId);
      // Only a genuine new *selection* focuses the camera — checking
      // selectedId specifically (not effectiveId) means a hover alone
      // never moves the map, matching "when someone clicks" rather than
      // "when someone mouses over."
      if (next.selectedId != null && next.selectedId != previous?.selectedId) {
        _focusOnAmbulance(next.selectedId!);
      }
    });

    if (!state.hasLoadedOnce) {
      return const Center(child: CircularProgressIndicator());
    }

    final entries = state.info.values
        .where((info) => widget.filter == AmbulanceViewFilter.all || !info.location.isTransporting)
        .toList();

    if (entries.isEmpty) {
      return EmptyState(
        graphic: EmptyStateGraphic.chartPulse,
        title: widget.filter == AmbulanceViewFilter.emptyOnly
            ? 'No empty ambulances right now'
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
          // Dims every marker except the highlighted one (both stay fully
          // opaque when nothing's highlighted) and raises the highlighted
          // one to the front — the same "make the selected one visually
          // pop" signal AmbulanceCard's own border gives on the list side,
          // without needing a whole extra set of highlighted-variant icon
          // bitmaps.
          alpha: highlightedId == null || highlightedId == entry.location.ambulanceId ? 1.0 : 0.55,
          zIndexInt: highlightedId == entry.location.ambulanceId ? 1 : 0,
          onTap: () => ref.read(ambulanceHighlightProvider.notifier).select(entry.location.ambulanceId),
          infoWindow: InfoWindow(
            title: entry.location.ambulanceId,
            snippet: _infoWindowSnippet(entry),
          ),
        ),
    };

    return GoogleMap(
      initialCameraPosition: CameraPosition(target: points.first, zoom: 12),
      onMapCreated: (controller) {
        _mapController = controller;
        _fitToPoints(points);
        // MainViewScreen disposes and recreates this widget when it swaps
        // between the mobile ambulance-list and map views — a selection
        // made while the list was showing (and this instance didn't
        // exist) fires before this widget's own ref.listen above can ever
        // see it. Catch up on whatever's already selected the instant the
        // map connects, so returning to the map still focuses it.
        // Double-animates alongside _fitToPoints on this one path
        // (fleet-fit, then zoom-in) — a bit busy, but correct.
        final selectedId = ref.read(ambulanceHighlightProvider).selectedId;
        if (selectedId != null) _focusOnAmbulance(selectedId);
      },
      markers: markers,
    );
  }
}
