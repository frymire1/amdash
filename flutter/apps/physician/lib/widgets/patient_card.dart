import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/directions_service.dart';
import '../services/ems_location_service.dart';

/// Mirrors `patient-card.component.ts`/`.html`/`.scss`: a clickable patient
/// summary card with a live-tracking status badge (pulsing dot when
/// online) and a vitals grid, each field falling back to "Not added yet"
/// via [isProvidedValue] (EMS leaves required fields as the literal
/// string `'Unknown'` when left blank on upload).
class PatientCard extends ConsumerWidget {
  const PatientCard({required this.patient, required this.trackingStatus, required this.onTap, super.key});

  final Patient patient;
  final EmsTrackingStatus trackingStatus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Same cache PatientViewer populates — only present once a patient's
    // been actively tracked and viewed at least once (the fetch is
    // triggered from there, not from this card), so most cards simply
    // won't have an ETA yet.
    final cachedRoute = patient.id == null
        ? null
        : ref.watch(directionsCacheProvider.select((cache) => cache[patient.id]));

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
              if (cachedRoute != null) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'ETA: ${cachedRoute.result.durationText}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
              Text(
                isProvidedValue(patient.name) ? patient.name : 'Not added yet',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                '${_fallback(patient.gender)} · ${_fallback(patient.age)}',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Text(
                'Healthcare #: ${_fallback(patient.healthcareNumber)}',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              Text(
                'Destination: ${_fallback(patient.destination)}',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _fieldChip(context, 'GCS', patient.vitals.gcs),
                  _fieldChip(context, 'Heart Rate', patient.vitals.heartRate),
                  _fieldChip(context, 'Blood Pressure', patient.vitals.bloodPressure),
                  _fieldChip(context, 'Oxygen', patient.vitals.oxygen),
                  _fieldChip(context, 'Temp', patient.vitals.temperature),
                  _fieldChip(context, 'Resp. Rate', patient.vitals.respiratoryRate),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fallback(Object? value) => isProvidedValue(value) ? value.toString() : 'Not added yet';

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

  Widget _fieldChip(BuildContext context, String label, Object? value) {
    final provided = isProvidedValue(value);
    final palette = context.palette;
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: palette.glassSurface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant)),
          Text(
            provided ? value.toString() : 'Not added yet',
            style: TextStyle(
              fontSize: 13,
              fontStyle: provided ? FontStyle.normal : FontStyle.italic,
              color: provided ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
