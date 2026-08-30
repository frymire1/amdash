import 'dart:ui';

import 'package:amdash_core/amdash_core.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../classes/active_location.dart';
import '../services/directions_service.dart';
import '../services/ems_location_service.dart';
import '../utils/geo.dart';

const _directionsRefreshMs = 15000;
const _directionsRefreshDistanceM = 75.0;

// Google's own DirectionsRenderer default route color — Angular never
// customized this (see git history), so this just approximates what its
// default styling looked like; google_maps_flutter's Polyline has no
// "use the default" option, so the values have to be picked explicitly.
const _routeColor = Color(0xFF1A73E8);
const _routeWidth = 6;

/// Mirrors `patient-viewer.component.ts`/`.html` — the core screen: patient
/// info/vitals cards, a live map with the animated EMS vehicle marker
/// (lerped between Firestore fixes over the real elapsed wall-clock gap —
/// not a fixed-duration Tween), the destination hospital, and a throttled
/// Directions route overlay. There's no separate "pickup location" marker —
/// EMS's device position at patient-creation time is only ever used to seed
/// the very first `patients/{id}/location/current` fix (see
/// `uploadPatientDocument`), never stored on the patient doc itself, so the
/// vehicle marker above is the only location this screen ever has to show.
///
/// Tracking status ([EmsTrackingStatus], from `emsTrackingInfo`) and the
/// cached route ([DirectionsCacheEntry], from `directionsCacheProvider`) are
/// read reactively via `ref.watch` inside [build] for anything that's a pure
/// function of current state, so it's always correct on the very first
/// frame (no waiting for a Firestore change event to "catch up"), and
/// survives this widget being disposed and recreated (e.g. switching to a
/// different patient and back — confirmed via a real report that a
/// locally-held route disappeared in exactly that sequence, since a fresh
/// widget instance has no way to re-fetch a route for a patient that's no
/// longer actively tracked). Only the glide animation between two fixes,
/// and kicking off a Directions fetch, are genuine reactions to a *change*
/// and stay as `ref.listen`-driven imperative side effects.
class PatientViewer extends ConsumerStatefulWidget {
  const PatientViewer({required this.patient, this.leading, this.directionsService, super.key});

  final Patient? patient;

  /// Rendered above the patient's name, inside the same scrollable content
  /// — so it scrolls out of view with the rest of the page rather than
  /// floating over it. Used by [MainViewScreen] to place its mobile-only
  /// "Patient List" button without overlapping the name.
  final Widget? leading;

  /// Optional testability seam, mirroring [DirectionsService]'s own
  /// `FirebaseFunctions?` constructor param — the real call site never
  /// passes this (always defaults to a real `DirectionsService()`).
  /// Without it, a widget test has no way to reach
  /// `_maybeRequestDirections`'s success path at all: `DirectionsService()`
  /// itself constructs a real `FirebaseFunctions.instanceFor(...)`, which
  /// throws `[core/no-app]` the instant this widget mounts unless a real
  /// `Firebase.initializeApp()` has run (confirmed by `DirectionsService`'s
  /// own doc comment) — every `PatientViewer` test, not just directions-
  /// specific ones, needs this seam to construct the widget at all.
  final DirectionsService? directionsService;

  @override
  ConsumerState<PatientViewer> createState() => _PatientViewerState();
}

class _PatientViewerState extends ConsumerState<PatientViewer> {
  @override
  Widget build(BuildContext context) {
    final patient = widget.patient;

    if (patient == null) {
      return Column(
        children: [
          if (widget.leading != null) Padding(padding: const EdgeInsets.all(16), child: widget.leading),
          const Expanded(
            child: EmptyState(
              graphic: EmptyStateGraphic.chartPulse,
              title: 'Select a patient to view details',
              centered: true,
            ),
          ),
        ],
      );
    }

    // Only used here to decide whether the live map card should render at
    // all — everything else it needs (hospitals, tracking status, the
    // cached route, the glide animation) it reads and reacts to itself, so
    // it stays correctly live both inline and in the pushed full-screen
    // route (see _LiveMapCard's own doc comment for why).
    final hasKnownLocation = emsTrackingInfo(ref, patient.id).location != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.leading != null) ...[
            Align(alignment: Alignment.centerLeft, child: widget.leading),
            const SizedBox(height: 12),
          ],
          PatientFieldText(
            patient.name,
            notAddedText: 'Not added by EMS yet',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          Text.rich(
            TextSpan(
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              children: [
                if (isProvidedValue(patient.age))
                  TextSpan(text: '${patient.age} years')
                else ...[
                  const TextSpan(text: 'Age: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  const TextSpan(text: 'unknown'),
                ],
                const TextSpan(text: ' · '),
                if (isProvidedValue(patient.gender))
                  TextSpan(text: patient.gender)
                else ...[
                  const TextSpan(text: 'Gender: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  const TextSpan(text: 'unknown'),
                ],
              ],
            ),
          ),
          PatientFieldText(
            patient.healthcareNumber,
            prefix: 'Healthcare #: ',
            notAddedText: 'Not added by EMS yet',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          PatientTextCard(title: 'Destination', text: patient.destination, notAddedText: 'Not added by EMS yet'),
          const SizedBox(height: 12),
          PatientVitalsCard(patient: patient),
          const SizedBox(height: 12),
          PatientTreatmentCard(patient: patient),
          const SizedBox(height: 12),
          if (isProvidedValue(patient.notes)) ...[
            PatientTextCard(title: 'Patient Notes', text: patient.notes!),
            const SizedBox(height: 12),
          ],
          if (hasKnownLocation)
            _LiveMapCard(patient: patient, directionsService: widget.directionsService),
        ],
      ),
    );
  }
}

/// The map + live-position + ETA card — a fully self-contained,
/// independently-reactive widget (not just a builder method) specifically
/// so the "expand" button can push a *second, separate instance* of it into
/// a full-screen route rather than reusing a single frozen widget snapshot.
///
/// The previous implementation built the map as a plain local variable and
/// handed that one `GoogleMap` instance straight to the pushed route's
/// `Scaffold(body: map)` — a widget object captured once, at the moment the
/// button was tapped, that never rebuilt again: `PatientViewer`'s own
/// `build()` kept producing fresh `GoogleMap`/marker/ETA widgets for the
/// still-mounted (but now obscured) inline card, while the pushed route's
/// closure kept referencing that original, frozen object forever. Confirmed
/// via a real report: the expanded map never updated the vehicle's
/// position, and never showed the ETA/distance text at all, since only the
/// bare `GoogleMap` — not the card around it — was ever passed in.
///
/// Making this its own widget fixes both: each instance (inline or
/// full-screen) independently `ref.watch`es the same live providers
/// (`hospitalsProvider`, `emsLocationProvider`, `directionsCacheProvider`)
/// and owns its own glide-animation ticker/map controller/directions-fetch
/// guard, so a full-screen instance is exactly as live as the inline one —
/// genuinely the same card, just presented full screen, not a stand-in.
class _LiveMapCard extends ConsumerStatefulWidget {
  const _LiveMapCard({required this.patient, this.directionsService, this.fullScreen = false});

  final Patient patient;
  final DirectionsService? directionsService;

  /// True only for the instance pushed by [_openExpandedMap] — swaps the
  /// fixed-height inline map box for one that fills the whole screen, and
  /// drops the (now-redundant, and non-functional-while-already-expanded)
  /// header row/expand button in favor of a real `AppBar`.
  final bool fullScreen;

  @override
  ConsumerState<_LiveMapCard> createState() => _LiveMapCardState();
}

class _LiveMapCardState extends ConsumerState<_LiveMapCard> with TickerProviderStateMixin {
  late final DirectionsService _directionsService = widget.directionsService ?? DirectionsService();

  GoogleMapController? _mapController;
  Ticker? _ticker;

  // Non-null only while a glide animation is actively lerping between two
  // fixes; build() falls back to the current known location directly
  // whenever this is null, so the first-ever fix for an already-tracked
  // patient renders immediately without needing the ticker at all.
  LatLng? _tickerPosition;

  // Guards against firing a duplicate concurrent Cloud Function call for the
  // same patient while one's already in flight from this widget instance —
  // deliberately local/ephemeral (unlike the route cache itself): if this
  // widget disposes mid-fetch, a freshly recreated instance deciding to
  // re-fetch is fine, since it checks the surviving cache's own timestamp.
  final Set<String> _pendingDirectionsFetches = {};

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  LatLng? _locationLatLng(ActiveLocation? location) {
    if (location?.latitude == null || location?.longitude == null) return null;
    return LatLng(location!.latitude!, location.longitude!);
  }

  void _onLocationChanged(String patientId, ActiveLocation? location, Hospital? destinationHospital) {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;

    final position = _locationLatLng(location);
    if (position == null) {
      setState(() => _tickerPosition = null);
      return;
    }

    final hasPreviousFix = location!.previousLatitude != null &&
        location.previousLongitude != null &&
        location.previousUpdatedAtMs != null &&
        location.previousUpdatedAtMs! < location.updatedAtMs;

    if (!hasPreviousFix) {
      // build() already reads the current position straight from `location`
      // — no ticker needed for a fix with nothing to glide from.
      setState(() => _tickerPosition = null);
      _maybeRequestDirections(patientId, position, destinationHospital);
      return;
    }

    final startLat = location.previousLatitude!;
    final startLng = location.previousLongitude!;
    final endLat = location.latitude!;
    final endLng = location.longitude!;
    final startMs = location.previousUpdatedAtMs!;
    final durationMs = location.updatedAtMs - startMs;

    _ticker = createTicker((_) {
      final nowMs = clock.now().millisecondsSinceEpoch;
      final t = ((nowMs - startMs) / durationMs).clamp(0.0, 1.0);
      final lerped = LatLng(startLat + (endLat - startLat) * t, startLng + (endLng - startLng) * t);
      setState(() => _tickerPosition = lerped);
      if (t >= 1) {
        _ticker?.stop();
        _maybeRequestDirections(patientId, lerped, destinationHospital);
      }
    })..start();
  }

  Future<void> _maybeRequestDirections(String patientId, LatLng origin, Hospital? destinationHospital) async {
    if (destinationHospital == null) return;
    final destination = LatLng(destinationHospital.latitude, destinationHospital.longitude);

    final cacheNotifier = ref.read(directionsCacheProvider.notifier);
    final existing = cacheNotifier.entryFor(patientId);

    final nowMs = clock.now().millisecondsSinceEpoch;
    final dueByTime = existing == null || nowMs - existing.requestedAtMs >= _directionsRefreshMs;
    final dueByDistance = existing == null ||
        distanceMeters(
              existing.origin.latitude,
              existing.origin.longitude,
              origin.latitude,
              origin.longitude,
            ) >=
            _directionsRefreshDistanceM;
    if (!dueByTime && !dueByDistance) return;
    if (_pendingDirectionsFetches.contains(patientId)) return;

    _pendingDirectionsFetches.add(patientId);
    try {
      final result = await _directionsService.fetchDirections(origin: origin, destination: destination);
      // A transient failure or an empty result (e.g. a momentary Directions
      // API hiccup) shouldn't erase an already-good cached route — only
      // replace it once a genuinely new one arrives.
      if (result == null) return;
      cacheNotifier.store(patientId, DirectionsCacheEntry(result: result, requestedAtMs: nowMs, origin: origin));
      // Mirrors DirectionsRenderer's default auto-fit-to-route behavior
      // (Angular never set preserveViewport, so this was always on).
      if (mounted && result.polylinePoints.isNotEmpty) {
        _mapController?.animateCamera(
          CameraUpdate.newLatLngBounds(_boundsFromPoints(result.polylinePoints), 40),
        );
      }
    } catch (_) {
      // Same reasoning — keep showing the last known cached route rather
      // than clearing it on a transient fetch failure.
    } finally {
      _pendingDirectionsFetches.remove(patientId);
    }
  }

  LatLngBounds _boundsFromPoints(List<LatLng> points) {
    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;
    for (final point in points) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }
    return LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
  }

  void _openExpandedMap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _LiveMapCard(
          patient: widget.patient,
          directionsService: widget.directionsService,
          fullScreen: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final patient = widget.patient;

    final hospitals = ref.watch(hospitalsProvider).valueOrNull ?? const [];
    Hospital? destinationHospital;
    for (final hospital in hospitals) {
      if (hospital.name == patient.destination) {
        destinationHospital = hospital;
        break;
      }
    }

    final trackingInfo = emsTrackingInfo(ref, patient.id);
    final trackingStatus = trackingInfo.status;
    final trackedLocation = trackingInfo.location;

    final cachedRoute = patient.id == null
        ? null
        : ref.watch(directionsCacheProvider.select((cache) => cache[patient.id]));

    if (patient.id != null) {
      ref.listen<ActiveLocation?>(
        emsLocationProvider.select((s) => s.info[patient.id]?.location),
        (previous, next) => _onLocationChanged(patient.id!, next, destinationHospital),
      );
    }

    final vehiclePosition = _tickerPosition ?? _locationLatLng(trackedLocation);
    // Shouldn't happen given the parent's own hasKnownLocation gate, but
    // stay defensive rather than force-unwrap a null straight into the map.
    if (vehiclePosition == null) return const SizedBox.shrink();

    // Fetch for `stale` too, not just `active` — the last known *position*
    // already survives a page refresh (rebuilt from Firestore's own
    // document, not client state), so a route computed from that position
    // is just as recoverable, even though the patient isn't actively
    // publishing right now. Without this, a refresh while stale had no way
    // to ever get a route back, since nothing re-triggers once status can
    // no longer reach `active`.
    //
    // ref.listen above only fires on a *change*, so an already-tracked
    // patient wouldn't otherwise get its first Directions fetch kicked off
    // until EMS's next ~15s publish — vehiclePosition itself is already
    // correct on this first frame (computed straight from the reactively
    // watched trackedLocation above), but the fetch still needs a trigger.
    // Safe to call on every build: the throttling inside
    // _maybeRequestDirections makes this a no-op once a request is already
    // in flight or a result already exists.
    final isTracked = trackingStatus == EmsTrackingStatus.active || trackingStatus == EmsTrackingStatus.stale;
    if (patient.id != null && isTracked && destinationHospital != null && cachedRoute == null) {
      _maybeRequestDirections(patient.id!, vehiclePosition, destinationHospital);
    }

    final hospitalPosition = destinationHospital == null
        ? null
        : LatLng(destinationHospital.latitude, destinationHospital.longitude);
    final directionsResult = cachedRoute?.result;

    final map = GoogleMap(
      initialCameraPosition: CameraPosition(target: vehiclePosition, zoom: 15),
      onMapCreated: (controller) {
        _mapController = controller;
        // The route can finish loading before the platform view itself is
        // ready — confirmed via a real run: animateCamera was called with
        // _mapController still null (the fetch beat GoogleMap's own
        // initialization), so the very first camera-fit was silently
        // dropped and the map stayed at its initial vehicle-centered view.
        // If a route already arrived by the time the controller connects,
        // fit to it immediately instead of waiting for the next refresh.
        if (directionsResult != null && directionsResult.polylinePoints.isNotEmpty) {
          controller.animateCamera(
            CameraUpdate.newLatLngBounds(_boundsFromPoints(directionsResult.polylinePoints), 40),
          );
        }
      },
      markers: {
        Marker(
          markerId: const MarkerId('vehicle'),
          position: vehiclePosition,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        ),
        if (hospitalPosition != null)
          Marker(
            markerId: const MarkerId('hospital'),
            position: hospitalPosition,
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          ),
      },
      polylines: {
        if (directionsResult != null)
          Polyline(
            polylineId: const PolylineId('route'),
            points: directionsResult.polylinePoints,
            color: _routeColor,
            width: _routeWidth,
          ),
      },
    );

    final mapBox = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: AppColors.trackingAccent, width: 2)),
        child: Stack(
          children: [
            Positioned.fill(child: map),
            // Blur while a route is expected but not cached yet — this
            // patient has (or had) a known position and a destination
            // exists, so a route is fetchable, whether they're currently
            // active or stale (a stale patient's last known position still
            // survives, e.g. across a page refresh — see
            // _maybeRequestDirections). A never-tracked patient's status
            // never reaches active/stale at all, so this never shows for
            // them — no spinner spinning forever waiting for a route that
            // isn't coming. Only gates the *first* load: once a route is
            // cached, it's kept even during later refreshes, so this never
            // reappears.
            if (destinationHospital != null &&
                (trackingStatus == EmsTrackingStatus.active || trackingStatus == EmsTrackingStatus.stale) &&
                directionsResult == null)
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.15),
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.fullScreen) ...[
          Row(
            children: [
              const Expanded(
                child: Text('Current Location', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              IconButton(onPressed: _openExpandedMap, icon: const Icon(Icons.open_in_full), tooltip: 'Expand map'),
            ],
          ),
          const SizedBox(height: 8),
        ],
        widget.fullScreen ? Expanded(child: mapBox) : SizedBox(height: 260, child: mapBox),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: trackingStatus == EmsTrackingStatus.active
              ? Text(
                  'Live position: ${vehiclePosition.latitude.toStringAsFixed(4)}, '
                  '${vehiclePosition.longitude.toStringAsFixed(4)}',
                  style: TextStyle(color: AppColors.trackingAccent, fontSize: 12),
                )
              : Text(
                  'Last updated at: '
                  '${DateFormat('h:mm:ss a').format(DateTime.fromMillisecondsSinceEpoch(trackedLocation!.updatedAtMs))}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
        ),
        if (directionsResult != null && destinationHospital != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'ETA: ${directionsResult.durationText} · Distance: ${directionsResult.distanceText} '
              'to ${destinationHospital.name}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );

    if (widget.fullScreen) {
      return Scaffold(
        appBar: AppBar(title: const Text('Current Location')),
        body: Padding(padding: const EdgeInsets.all(16), child: body),
      );
    }

    return Card(child: Padding(padding: const EdgeInsets.all(16), child: body));
  }
}
