import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';

import '../services/ems_location_service.dart';

/// Mirrors `patient-card.component.ts`/`.html`/`.scss`: a clickable patient
/// summary card with a live-tracking status badge (pulsing dot when
/// online) and a vitals grid, each field falling back to "Not added yet"
/// via [isProvidedValue] (EMS leaves required fields as the literal
/// string `'Unknown'` when left blank on upload).
class PatientCard extends StatelessWidget {
  const PatientCard({required this.patient, required this.trackingStatus, required this.onTap, super.key});

  final Patient patient;
  final EmsTrackingStatus trackingStatus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(alignment: Alignment.centerRight, child: _TrackingBadge(status: trackingStatus)),
              Text(
                isProvidedValue(patient.name) ? patient.name : 'Not added yet',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                '${_fallback(patient.gender)} · ${_fallback(patient.age)}',
                style: TextStyle(color: AppColors.slate500),
              ),
              const SizedBox(height: 4),
              Text('Healthcare #: ${_fallback(patient.healthcareNumber)}', style: TextStyle(color: AppColors.slate500)),
              Text('Destination: ${_fallback(patient.destination)}', style: TextStyle(color: AppColors.slate500)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _fieldChip('GCS', patient.vitals.gcs),
                  _fieldChip('Heart Rate', patient.vitals.heartRate),
                  _fieldChip('Blood Pressure', patient.vitals.bloodPressure),
                  _fieldChip('Oxygen', patient.vitals.oxygen),
                  _fieldChip('Temp', patient.vitals.temperature),
                  _fieldChip('Resp. Rate', patient.vitals.respiratoryRate),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fallback(Object? value) => isProvidedValue(value) ? value.toString() : 'Not added yet';

  Widget _fieldChip(String label, Object? value) {
    final provided = isProvidedValue(value);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: AppColors.slate500)),
          Text(
            provided ? value.toString() : 'Not added yet',
            style: TextStyle(
              fontSize: 13,
              fontStyle: provided ? FontStyle.normal : FontStyle.italic,
              color: provided ? AppColors.slate900 : AppColors.slate400,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackingBadge extends StatefulWidget {
  const _TrackingBadge({required this.status});

  final EmsTrackingStatus status;

  @override
  State<_TrackingBadge> createState() => _TrackingBadgeState();
}

class _TrackingBadgeState extends State<_TrackingBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (color, label, pulsing) = switch (widget.status) {
      EmsTrackingStatus.active => (AppColors.success, 'Tracking Online', true),
      EmsTrackingStatus.stale => (AppColors.warning, 'Lost Connection', false),
      EmsTrackingStatus.noData => (AppColors.danger, 'Tracking Offline', false),
      // Normally sub-second (first Firestore snapshot) — shouldn't flash
      // "Offline" before the real answer is known.
      EmsTrackingStatus.loading => (AppColors.slate400, 'Tracking…', false),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        const SizedBox(width: 6),
        if (pulsing)
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _controller.value;
              return Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: (0.6 * (1 - t)).clamp(0, 1)),
                      spreadRadius: 8 * t,
                    ),
                  ],
                ),
              );
            },
          )
        else
          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
      ],
    );
  }
}
