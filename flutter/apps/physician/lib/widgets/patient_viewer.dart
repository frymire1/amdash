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

// Google's own DirectionsRenderer default route color so this just approximates what its
// default styling looked like; google_maps_flutter's Polyline has no
// "use the default" option, so the values have to be picked explicitly).
const _routeColor = Color(0xFF1A73E8);
const _routeWidth = 6;

/// Mirrors `patient-viewer.component.ts`/`.html` — the core screen: patient
/// info/vitals cards, a live map with the static pickup location, the
/// animated EMS vehicle marker (lerped between Firestore fixes over the
/// real elapsed wall-clock gap — not a fixed-duration Tween), the
/// destination hospital, and a throttled Directions route overlay.
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
  LatLng? _animatedVehiclePosition;
  DirectionsResult? _directionsResult;
  int? _lastDirectionsRequestAtMs;
  LatLng? _lastRequestedOrigin;

  // Whether EMS is *currently* actively publishing a fix for this patient.
  // The vehicle position/route themselves are deliberately NOT cleared when
  // this goes false — a patient briefly going inactive shouldn't erase
  // useful context — this flag just gates the "Live position"/"Last
  // updated at" wording near the bottom of the map card.
  bool _isLive = false;
  int? _lastFixUpdatedAtMs;

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  void _onActiveLocationChanged(ActiveLocation? location, Hospital? destinationHospital) {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;

    if (location?.latitude == null || location?.longitude == null) {
      // Deliberately don't clear _animatedVehiclePosition/_directionsResult
      // here — keep showing the last known position/route until a new fix
      // arrives, per the design above.
      setState(() => _isLive = false);
      return;
    }

    final fix = location!;
    setState(() => _isLive = true);
    _lastFixUpdatedAtMs = fix.updatedAtMs;

    final hasPreviousFix = fix.previousLatitude != null &&
        fix.previousLongitude != null &&
        fix.previousUpdatedAtMs != null &&
        fix.previousUpdatedAtMs! < fix.updatedAtMs;

    if (!hasPreviousFix) {
      final position = LatLng(fix.latitude!, fix.longitude!);
      setState(() => _animatedVehiclePosition = position);
      _maybeRequestDirections(position, destinationHospital);
      return;
    }

    final startLat = fix.previousLatitude!;
    final startLng = fix.previousLongitude!;
    final endLat = fix.latitude!;
    final endLng = fix.longitude!;
    final startMs = fix.previousUpdatedAtMs!;
    final durationMs = fix.updatedAtMs - startMs;

    _ticker = createTicker((_) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final t = ((nowMs - startMs) / durationMs).clamp(0.0, 1.0);
      final position = LatLng(startLat + (endLat - startLat) * t, startLng + (endLng - startLng) * t);
      setState(() => _animatedVehiclePosition = position);
      if (t >= 1) {
        _ticker?.stop();
        _maybeRequestDirections(position, destinationHospital);
      }
    })..start();
  }

  void _resetDirections() {
    setState(() => _directionsResult = null);
    _lastDirectionsRequestAtMs = null;
    _lastRequestedOrigin = null;
  }

  Future<void> _maybeRequestDirections(LatLng origin, Hospital? destinationHospital) async {
    if (destinationHospital == null) {
      _resetDirections();
      return;
    }
    final destination = LatLng(destinationHospital.latitude, destinationHospital.longitude);

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dueByTime =
        _lastDirectionsRequestAtMs == null || nowMs - _lastDirectionsRequestAtMs! >= _directionsRefreshMs;
    final dueByDistance = _lastRequestedOrigin == null ||
        distanceMeters(
              _lastRequestedOrigin!.latitude,
              _lastRequestedOrigin!.longitude,
              origin.latitude,
              origin.longitude,
            ) >=
            _directionsRefreshDistanceM;
    if (!dueByTime && !dueByDistance) return;

    _lastDirectionsRequestAtMs = nowMs;
    _lastRequestedOrigin = origin;

    try {
      final result = await _directionsService.fetchDirections(origin: origin, destination: destination);
      // A transient failure or an empty result (e.g. a momentary Directions
      // API hiccup) shouldn't erase an already-good route — only replace it
      // once a genuinely new one arrives.
      if (result == null) return;
      if (mounted) setState(() => _directionsResult = result);
      // Mirrors DirectionsRenderer's default auto-fit-to-route behavior
      // (Angular never set preserveViewport, so this was always on).
      if (result.polylinePoints.isNotEmpty) {
        _mapController?.animateCamera(
          CameraUpdate.newLatLngBounds(_boundsFromPoints(result.polylinePoints), 40),
        );
      }
    } catch (_) {
      // Same reasoning — keep showing the last known route rather than
      // clearing it on a transient fetch failure.
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

    ref.listen<ActiveLocation?>(
      emsLocationProvider.select((s) => patient.id == null ? null : s.activeLocations[patient.id]),
      (previous, next) => _onActiveLocationChanged(next, destinationHospital),
    );

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
            _mapCard(markerPosition, hospitalPosition, patient, destinationHospital),
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

  Widget _mapCard(LatLng markerPosition, LatLng? hospitalPosition, Patient patient, Hospital? destinationHospital) {
    final map = GoogleMap(
      initialCameraPosition: CameraPosition(target: markerPosition, zoom: 15),
      onMapCreated: (controller) => _mapController = controller,
      markers: {
        Marker(markerId: const MarkerId('pickup'), position: markerPosition),
        if (_animatedVehiclePosition != null)
          Marker(
            markerId: const MarkerId('vehicle'),
            position: _animatedVehiclePosition!,
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
        if (_directionsResult != null)
          Polyline(
            polylineId: const PolylineId('route'),
            points: _directionsResult!.polylinePoints,
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
                child: map,
              ),
            ),
            const SizedBox(height: 8),
            if (patient.location!.address.isNotEmpty) Text(patient.location!.address),
            Text(
              '${patient.location!.latitude.toStringAsFixed(4)}, ${patient.location!.longitude.toStringAsFixed(4)}',
              style: TextStyle(color: AppColors.slate500, fontSize: 12),
            ),
            if (_animatedVehiclePosition != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _isLive
                    ? Text(
                        'Live position: ${_animatedVehiclePosition!.latitude.toStringAsFixed(4)}, '
                        '${_animatedVehiclePosition!.longitude.toStringAsFixed(4)}',
                        style: TextStyle(color: AppColors.trackingAccent, fontSize: 12),
                      )
                    : Text(
                        _lastFixUpdatedAtMs == null
                            ? 'Not currently live-tracked'
                            : 'Last updated at: '
                                '${DateFormat('h:mm:ss a').format(DateTime.fromMillisecondsSinceEpoch(_lastFixUpdatedAtMs!))}',
                        style: TextStyle(color: AppColors.slate500, fontSize: 12, fontStyle: FontStyle.italic),
                      ),
              ),
            if (_directionsResult != null && destinationHospital != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'ETA: ${_directionsResult!.durationText} · Distance: ${_directionsResult!.distanceText} '
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
