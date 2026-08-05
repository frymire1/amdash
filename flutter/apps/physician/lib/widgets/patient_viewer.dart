import 'dart:ui';

import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../classes/active_location.dart';
import '../services/directions_service.dart';
import '../services/ems_location_service.dart';
import '../utils/geo.dart';

const _defaultMarkerPosition = LatLng(40.7128, -74.006);
const _directionsRefreshMs = 15000;
const _directionsRefreshDistanceM = 75.0;

// Google's own DirectionsRenderer default route color — Angular never
// customized this (see git history), so this just approximates what its
// default styling looked like; google_maps_flutter's Polyline has no
// "use the default" option, so the values have to be picked explicitly.
const _routeColor = Color(0xFF1A73E8);
const _routeWidth = 6;

/// Mirrors `patient-viewer.component.ts`/`.html` — the core screen: patient
/// info/vitals cards, a live map with the static pickup location, the
/// animated EMS vehicle marker (lerped between Firestore fixes over the
/// real elapsed wall-clock gap — not a fixed-duration Tween), the
/// destination hospital, and a throttled Directions route overlay.
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
  const PatientViewer({required this.patient, super.key});

  final Patient? patient;

  @override
  ConsumerState<PatientViewer> createState() => _PatientViewerState();
}

class _PatientViewerState extends ConsumerState<PatientViewer> with TickerProviderStateMixin {
  final DirectionsService _directionsService = DirectionsService();

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
      final nowMs = DateTime.now().millisecondsSinceEpoch;
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

    final nowMs = DateTime.now().millisecondsSinceEpoch;
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

  @override
  Widget build(BuildContext context) {
    final patient = widget.patient;

    if (patient == null) {
      return Center(
        child: Text('Select a patient to view details', style: TextStyle(color: AppColors.slate500)),
      );
    }

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
    if (patient.id != null && isTracked && vehiclePosition != null && destinationHospital != null && cachedRoute == null) {
      _maybeRequestDirections(patient.id!, vehiclePosition, destinationHospital);
    }

    final markerPosition = patient.location == null
        ? _defaultMarkerPosition
        : LatLng(patient.location!.latitude, patient.location!.longitude);
    final hospitalPosition = destinationHospital == null
        ? null
        : LatLng(destinationHospital.latitude, destinationHospital.longitude);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            isProvidedValue(patient.name) ? patient.name : 'Not added by EMS yet',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          Text.rich(
            TextSpan(
              style: TextStyle(color: AppColors.slate500),
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
          Text(
            'Healthcare #: ${isProvidedValue(patient.healthcareNumber) ? patient.healthcareNumber : 'Not added by EMS yet'}',
            style: TextStyle(color: AppColors.slate500),
          ),
          const SizedBox(height: 16),
          _infoCard('Destination Hospital', [_infoRow('Destination', patient.destination)]),
          const SizedBox(height: 12),
          _infoCard('Vital Signs', [
            _infoRow('Heart Rate', patient.vitals.heartRate, suffix: 'bpm'),
            _infoRow('Blood Pressure', patient.vitals.bloodPressure),
            _infoRow('Oxygen', patient.vitals.oxygen, suffix: '%'),
            _infoRow('Temperature', patient.vitals.temperature, suffix: '°C'),
            _infoRow('Respiratory Rate', patient.vitals.respiratoryRate, suffix: 'breaths/min'),
            _infoRow('GCS', patient.vitals.gcs),
          ], accent: true),
          const SizedBox(height: 12),
          _treatmentCard(patient),
          const SizedBox(height: 12),
          if (isProvidedValue(patient.notes)) ...[
            _textCard('Patient Notes', patient.notes!),
            const SizedBox(height: 12),
          ],
          if (patient.location != null)
            _mapCard(
              markerPosition,
              hospitalPosition,
              patient,
              destinationHospital,
              trackingStatus,
              trackedLocation,
              vehiclePosition,
              cachedRoute?.result,
            ),
        ],
      ),
    );
  }

  Widget _infoCard(String title, List<Widget> rows, {bool accent = false}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Wrap(spacing: 16, runSpacing: 12, children: rows),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, Object? value, {String? suffix}) {
    final provided = isProvidedValue(value);
    final text = provided ? (suffix == null ? '$value' : '$value $suffix') : 'Not added by EMS yet';
    return SizedBox(
      width: 200,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F9FF),
          border: Border(left: BorderSide(color: AppColors.trackingAccent, width: 3)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: AppColors.slate500)),
            Text(
              text,
              style: TextStyle(
                fontStyle: provided ? FontStyle.normal : FontStyle.italic,
                color: provided ? AppColors.slate900 : AppColors.slate400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _treatmentCard(Patient patient) {
    final treatmentProvided = isProvidedValue(patient.treatment);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Treatment / Medication Given', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              treatmentProvided ? patient.treatment! : 'Not added by EMS yet',
              style: TextStyle(
                fontStyle: treatmentProvided ? FontStyle.normal : FontStyle.italic,
                color: treatmentProvided ? null : AppColors.slate400,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                _infoRow('IV Size', patient.ivSize),
                _infoRow('IV Placement', patient.ivPlacement),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _textCard(String title, String text) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(text),
          ],
        ),
      ),
    );
  }

  Widget _mapCard(
    LatLng markerPosition,
    LatLng? hospitalPosition,
    Patient patient,
    Hospital? destinationHospital,
    EmsTrackingStatus trackingStatus,
    ActiveLocation? trackedLocation,
    LatLng? vehiclePosition,
    DirectionsResult? directionsResult,
  ) {
    final map = GoogleMap(
      initialCameraPosition: CameraPosition(target: markerPosition, zoom: 15),
      onMapCreated: (controller) {
        _mapController = controller;
        // The route can finish loading before the platform view itself is
        // ready — confirmed via a real run: animateCamera was called with
        // _mapController still null (the fetch beat GoogleMap's own
        // initialization), so the very first camera-fit was silently
        // dropped and the map stayed at its initial pickup-centered view.
        // If a route already arrived by the time the controller connects,
        // fit to it immediately instead of waiting for the next refresh.
        if (directionsResult != null && directionsResult.polylinePoints.isNotEmpty) {
          controller.animateCamera(
            CameraUpdate.newLatLngBounds(_boundsFromPoints(directionsResult.polylinePoints), 40),
          );
        }
      },
      markers: {
        Marker(markerId: const MarkerId('pickup'), position: markerPosition),
        if (vehiclePosition != null)
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Current Location', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  onPressed: () => _openExpandedMap(map),
                  icon: const Icon(Icons.open_in_full),
                  tooltip: 'Expand map',
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: 260,
                decoration: BoxDecoration(border: Border.all(color: AppColors.trackingAccent, width: 2)),
                child: Stack(
                  children: [
                    map,
                    // Blur while a route is expected but not cached yet —
                    // this patient has (or had) a known position and a
                    // destination exists, so a route is fetchable, whether
                    // they're currently active or stale (a stale patient's
                    // last known position still survives, e.g. across a page
                    // refresh — see _maybeRequestDirections). A never-tracked
                    // patient's status never reaches active/stale at all, so
                    // this never shows for them — no spinner spinning forever
                    // waiting for a route that isn't coming. Only gates the
                    // *first* load: once a route is cached, it's kept even
                    // during later refreshes, so this never reappears.
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
            ),
            const SizedBox(height: 8),
            if (patient.location!.address.isNotEmpty) Text(patient.location!.address),
            Text(
              '${patient.location!.latitude.toStringAsFixed(4)}, ${patient.location!.longitude.toStringAsFixed(4)}',
              style: TextStyle(color: AppColors.slate500, fontSize: 12),
            ),
            if (vehiclePosition != null)
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
                        style: TextStyle(color: AppColors.slate500, fontSize: 12, fontStyle: FontStyle.italic),
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
        ),
      ),
    );
  }

  void _openExpandedMap(Widget map) {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => Scaffold(appBar: AppBar(), body: map)));
  }
}
