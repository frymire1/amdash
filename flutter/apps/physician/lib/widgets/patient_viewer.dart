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

const _directionsRefreshMs = 15000;
const _directionsRefreshDistanceM = 75.0;

// Google's own DirectionsRenderer default route color — Angular never
// customized this (see git history), so this just approximates what its
// default styling looked like; google_maps_flutter's Polyline has no
// "use the default" option, so the values have to be picked explicitly.
const _routeColor = Color(0xFF1A73E8);
const _routeWidth = 6;

/// `PatientVitals`' numeric-ish fields (heartRate/oxygen/temperature) are
/// typed `Object?` because they can also be the 'Unknown' string sentinel
/// (see `_sharedFields` in patient_upload_service.dart) — used by
/// `_vitalsCard`'s trend-chart series selectors to filter those out rather
/// than plot them as zero.
num? _numOrNull(Object? value) => value is num ? value : null;

/// Splits a "120/80"-shaped blood pressure reading into its systolic
/// (index 0) or diastolic (index 1) half, or null if it isn't in that
/// shape at all (missing, or the 'Unknown' sentinel — splitting either by
/// '/' yields a single-element list, so this returns null for both parts
/// without needing to special-case the sentinel directly).
num? _bloodPressurePart(String bloodPressure, int index) {
  final parts = bloodPressure.split('/');
  if (parts.length != 2) return null;
  return num.tryParse(parts[index].trim());
}

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
  const PatientViewer({required this.patient, this.leading, super.key});

  final Patient? patient;

  /// Rendered above the patient's name, inside the same scrollable content
  /// — so it scrolls out of view with the rest of the page rather than
  /// floating over it. Used by [MainViewScreen] to place its mobile-only
  /// "Patient List" button without overlapping the name.
  final Widget? leading;

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

  bool _exportingFhir = false;
  String? _exportError;

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

  // Only ever offered once the org has opted in and this patient's
  // transport is actually complete — see canExportFhir in build(). The
  // callable (functions/src/patients.ts) enforces both as hard
  // preconditions regardless, this just avoids showing a button that
  // would always fail.
  Future<void> _exportFhir(String patientId, Patient patient) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Export FHIR record?',
      message:
          "This downloads an unencrypted file containing ${patient.name.display()}'s information to your device. "
          "AmDash's own access controls no longer apply to it once saved.",
      confirmLabel: 'Download',
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _exportingFhir = true;
      _exportError = null;
    });

    try {
      await exportPatientFhirBundle(ref.read(fhirExportFunctionsProvider), patientId);
    } on FhirExportException catch (error) {
      if (mounted) setState(() => _exportError = error.message);
    } catch (error) {
      if (mounted) setState(() => _exportError = "Couldn't export this patient's FHIR record. Please try again.");
    } finally {
      if (mounted) setState(() => _exportingFhir = false);
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

    final patientId = patient.id;
    final canExportFhir = patientId != null &&
        patient.status == 'completed' &&
        (ref.watch(ownOrganizationProvider).valueOrNull?.fhirExportEnabled ?? false);

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

    final hospitalPosition = destinationHospital == null
        ? null
        : LatLng(destinationHospital.latitude, destinationHospital.longitude);

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
          if (canExportFhir) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _exportingFhir ? null : () => _exportFhir(patientId, patient),
                icon: _exportingFhir
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload_file),
                label: Text(_exportingFhir ? 'Exporting…' : 'Export FHIR record'),
              ),
            ),
          ],
          if (_exportError != null) ...[
            const SizedBox(height: 8),
            Text(_exportError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          _infoCard('Destination Hospital', [_infoRow('Destination', patient.destination)]),
          const SizedBox(height: 12),
          _vitalsCard(patient),
          const SizedBox(height: 12),
          _treatmentCard(patient),
          const SizedBox(height: 12),
          if (isProvidedValue(patient.notes)) ...[
            _textCard('Patient Notes', patient.notes!),
            const SizedBox(height: 12),
          ],
          if (vehiclePosition != null)
            _mapCard(
              vehiclePosition,
              hospitalPosition,
              destinationHospital,
              trackingStatus,
              trackedLocation,
              cachedRoute?.result,
            ),
        ],
      ),
    );
  }

  Widget _infoCard(String title, List<Widget> rows) {
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

  // Same shape as _infoCard, but the header carries a "Recorded {time}"
  // stamp from the latest vitalsHistoryProvider entry. Used to let you
  // step back through older readings inline (arrow buttons swapping which
  // snapshot the whole card showed) — replaced by a per-vital trend icon
  // in _infoRow instead (see showVitalsTrendDialog), so this card always
  // shows the patient's current vitals and history browsing only happens
  // through that dialog. Falls back to patient.vitals with no timestamp
  // while history is still loading, or for a patient that predates this
  // feature (no history entries exist for it at all).
  Widget _vitalsCard(Patient patient) {
    final patientId = patient.id;
    final history = patientId == null ? const <VitalsHistoryEntry>[] : ref.watch(vitalsHistoryProvider(patientId)).valueOrNull ?? const [];
    final vitals = patient.vitals;
    final latestRecordedAt = history.isEmpty ? null : history.first.recordedAt;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Vital Signs', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Text(
                latestRecordedAt == null
                    ? 'No upload history recorded for this patient'
                    : 'Recorded ${DateFormat('MMM d, h:mm a').format(latestRecordedAt)}',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                _infoRow(
                  'Heart Rate',
                  vitals.heartRate,
                  suffix: 'bpm',
                  history: history,
                  trendSeries: [VitalSeries(label: 'Heart Rate', selector: (v) => _numOrNull(v.heartRate))],
                ),
                _infoRow(
                  'Blood Pressure',
                  vitals.bloodPressure,
                  history: history,
                  trendSeries: [
                    VitalSeries(label: 'Systolic', selector: (v) => _bloodPressurePart(v.bloodPressure, 0), color: AppColors.trackingAccent),
                    VitalSeries(label: 'Diastolic', selector: (v) => _bloodPressurePart(v.bloodPressure, 1), color: AppColors.brand),
                  ],
                ),
                _infoRow(
                  'Oxygen',
                  vitals.oxygen,
                  suffix: '%',
                  history: history,
                  trendSeries: [VitalSeries(label: 'Oxygen', selector: (v) => _numOrNull(v.oxygen))],
                ),
                _infoRow(
                  'Temperature',
                  vitals.temperature,
                  suffix: '°C',
                  history: history,
                  trendSeries: [VitalSeries(label: 'Temperature', selector: (v) => _numOrNull(v.temperature))],
                ),
                _infoRow(
                  'Respiratory Rate',
                  vitals.respiratoryRate,
                  suffix: 'breaths/min',
                  history: history,
                  trendSeries: [VitalSeries(label: 'Respiratory Rate', selector: (v) => v.respiratoryRate)],
                ),
                _infoRow(
                  'GCS',
                  vitals.gcs,
                  history: history,
                  trendSeries: [VitalSeries(label: 'GCS', selector: (v) => v.gcs)],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // [trendSeries]/[history] are only passed by _vitalsCard — every other
  // call site (IV size/placement, etc.) leaves them at their defaults and
  // gets no trend icon, since there's no history for those fields at all.
  Widget _infoRow(
    String label,
    Object? value, {
    String? suffix,
    List<VitalSeries>? trendSeries,
    List<VitalsHistoryEntry> history = const [],
  }) {
    final provided = isProvidedValue(value);
    final text = provided ? (suffix == null ? '$value' : '$value $suffix') : 'Not added by EMS yet';
    final palette = context.palette;
    final colorScheme = Theme.of(context).colorScheme;
    // A single reading isn't a trend — the icon only appears once there's
    // actually something to chart.
    final showTrend = trendSeries != null && history.length > 1;
    return SizedBox(
      width: 200,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: palette.glassSurface,
          border: Border(left: BorderSide(color: AppColors.trackingAccent, width: 3)),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(label, style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant)),
                ),
                if (showTrend)
                  InkWell(
                    // Keyed (rather than found by ancestor/type) because
                    // MainViewScreen wraps PatientViewer in its own Row for
                    // its wide-layout mode — a Row-typed ancestor search
                    // from this row's label text would also match that
                    // outer Row, pulling in every other vital's trend icon
                    // as a false-positive descendant match.
                    key: Key('vitals_trend_$label'),
                    onTap: () => showVitalsTrendDialog(
                      context,
                      title: label,
                      history: history,
                      series: trendSeries,
                      unit: suffix == null ? null : ' $suffix',
                    ),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(Icons.show_chart, size: 14, color: AppColors.trackingAccent),
                    ),
                  ),
              ],
            ),
            Text(
              text,
              style: TextStyle(
                fontStyle: provided ? FontStyle.normal : FontStyle.italic,
                color: provided ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
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
                color: treatmentProvided ? null : Theme.of(context).colorScheme.onSurfaceVariant,
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
    LatLng vehiclePosition,
    LatLng? hospitalPosition,
    Hospital? destinationHospital,
    EmsTrackingStatus trackingStatus,
    ActiveLocation? trackedLocation,
    DirectionsResult? directionsResult,
  ) {
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
        ),
      ),
    );
  }

  void _openExpandedMap(Widget map) {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => Scaffold(appBar: AppBar(), body: map)));
  }
}
