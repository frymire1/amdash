import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';

import '../services/ems_location_service.dart';

/// Mirrors `patient-card.component.ts`/`.html`/`.scss`: a clickable patient
/// summary card with a live-tracking status badge (pulsing dot when
/// online) and a vitals grid, each field falling back to "Not added yet"
/// via [isProvidedValue] (EMS leaves required fields as the literal
/// string `'Unknown'` when left blank on upload).
class PatientCard extends StatelessWidget {
  const PatientCard({
    required this.patient,
    required this.trackingStatus,
    required this.distanceToHospitalMeters,
    required this.onTap,
    super.key,
  });

  final Patient patient;
  final EmsTrackingStatus trackingStatus;

  /// Straight-line distance from the vehicle's last fix to its destination
  /// hospital, computed in [PatientList] from data already on the list —
  /// null when there's no location/hospital to measure between. This is the
  /// free, always-available proximity hint; the precise road ETA lives in
  /// [PatientViewer], which pays for a Directions API call to get it.
  final double? distanceToHospitalMeters;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(alignment: Alignment.centerRight, child: _trackingPill(trackingStatus)),
              // Distance is only meaningful while the vehicle is actively
              // reporting — hide it when tracking is stale/offline rather
              // than showing a distance from a last-known-but-abandoned fix.
              if (trackingStatus == EmsTrackingStatus.active && distanceToHospitalMeters != null) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${_formatDistance(distanceToHospitalMeters!)} from hospital',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
              PatientFieldText(
                patient.name,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                '${_fallback(patient.gender)} · ${_fallback(patient.age)}',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              PatientFieldText(
                patient.healthcareNumber,
                prefix: 'Healthcare #: ',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              Text(
                'Destination: ${_fallback(patient.destination)}',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              PatientVitalsChips(vitals: patient.vitals),
            ],
          ),
        ),
      ),
    );
  }

  String _fallback(Object? value) => isProvidedValue(value) ? value.toString() : 'Not added yet';

  // Metres under 1 km, one-decimal km above — "as the crow flies", so it's
  // deliberately a rough proximity read, not the road distance the viewer's
  // Directions-backed ETA gives.
  String _formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  Widget _trackingPill(EmsTrackingStatus status) {
    final (kind, label, pulsing) = switch (status) {
      EmsTrackingStatus.active => (StatusPillKind.active, 'Tracking Online', true),
      EmsTrackingStatus.stale => (StatusPillKind.warning, 'Lost Connection', false),
      EmsTrackingStatus.noData => (StatusPillKind.critical, 'Tracking Offline', false),
      // Normally sub-second (first Firestore snapshot) — shouldn't flash
      // "Offline" before the real answer is known.
      EmsTrackingStatus.loading => (StatusPillKind.neutral, 'Tracking…', false),
    };
    return StatusPill(kind: kind, label: label, pulsing: pulsing);
  }
}
