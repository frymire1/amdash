import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../classes/uploaded_patient.dart';
import '../services/ems_tracking_service.dart';
import '../services/patient_upload_service.dart';

/// Mirrors `patient-summary-card.component.ts`/`.html`.
class PatientSummaryCard extends ConsumerStatefulWidget {
  const PatientSummaryCard({super.key, required this.uploaded});

  final UploadedPatient uploaded;

  @override
  ConsumerState<PatientSummaryCard> createState() => _PatientSummaryCardState();
}

class _PatientSummaryCardState extends ConsumerState<PatientSummaryCard> {
  bool _deleting = false;
  bool _completing = false;
  String? _deleteError;
  String? _completeError;

  Future<void> _deletePatient() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete patient?',
      message: 'Delete ${widget.uploaded.patient.name}? This cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;

    // Flip this before the stopTracking/delete calls below, not after —
    // stopTracking alone can take a couple of seconds to tear down the
    // location stream, which is what looked like the button doing nothing.
    setState(() {
      _deleting = true;
      _deleteError = null;
    });

    try {
      await ref.read(emsTrackingProvider.notifier).stopTracking(widget.uploaded.id);
      await ref.read(patientUploadServiceProvider).deletePatient(widget.uploaded.id);
    } catch (error) {
      if (mounted) setState(() => _deleteError = 'Failed to delete patient. Please try again.');
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _completeTransport() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Complete transport?',
      message:
          "Mark ${widget.uploaded.patient.name}'s transport as complete? Live tracking will stop and it will no longer appear as active.",
      confirmLabel: 'Complete Transport',
    );
    if (!confirmed || !mounted) return;

    // Same ordering fix as _deletePatient — flip before stopTracking/complete.
    setState(() {
      _completing = true;
      _completeError = null;
    });

    try {
      await ref.read(emsTrackingProvider.notifier).stopTracking(widget.uploaded.id);
      await ref.read(patientUploadServiceProvider).completeTransport(widget.uploaded.id);
    } catch (error) {
      if (mounted) setState(() => _completeError = 'Failed to complete transport. Please try again.');
    } finally {
      if (mounted) setState(() => _completing = false);
    }
  }

  // Reflects real tracking health, not just whether tracking was started:
  // a degraded state (location off, permission revoked, or no GPS fix
  // coming through) shows a distinct, non-pulsing warning pill instead of
  // staying "Tracking Online".
  Widget _trackingPill(bool isTracking, EmsTrackingHealth? health) {
    if (!isTracking) {
      return const StatusPill(kind: StatusPillKind.critical, label: 'Tracking Offline', pulsing: false);
    }
    // Optimistic default while the first health check resolves (sub-second)
    // — avoids a flicker to a degraded label before we actually know.
    return switch (health ?? EmsTrackingHealth.online) {
      EmsTrackingHealth.online => const StatusPill(kind: StatusPillKind.active, label: 'Tracking Online', pulsing: true),
      EmsTrackingHealth.locationOff => const StatusPill(
        kind: StatusPillKind.warning,
        label: 'Location Off',
        pulsing: false,
      ),
      EmsTrackingHealth.permissionDenied => const StatusPill(
        kind: StatusPillKind.warning,
        label: 'Location Permission Off',
        pulsing: false,
      ),
      EmsTrackingHealth.noSignal => const StatusPill(
        kind: StatusPillKind.warning,
        label: 'No GPS Signal',
        pulsing: false,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final patient = widget.uploaded.patient;
    final isTracking = ref.watch(emsTrackingProvider).contains(widget.uploaded.id);
    // Only meaningful while tracking; skip the watch otherwise so an
    // untracked card doesn't spin up the health poller.
    final health = isTracking ? ref.watch(emsTrackingHealthProvider).valueOrNull : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: _trackingPill(isTracking, health),
            ),
            const SizedBox(height: 8),
            Text(patient.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text(
              'Healthcare #${patient.healthcareNumber}',
              style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(patient.gender),
                const SizedBox(width: 12),
                Text('${patient.age} yrs'),
                const SizedBox(width: 12),
                Text('${patient.vitals.heartRate} bpm'),
              ],
            ),
            if (_deleteError != null) ...[
              const SizedBox(height: 8),
              Text(_deleteError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (_completeError != null) ...[
              const SizedBox(height: 8),
              Text(_completeError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => context.push('/upload/${widget.uploaded.id}'),
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit'),
                ),
                OutlinedButton.icon(
                  onPressed: _completing ? null : _completeTransport,
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.success),
                  icon: _completing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.success),
                        )
                      : const Icon(Icons.check_circle),
                  label: Text(_completing ? 'Completing…' : 'Complete Transport'),
                ),
                OutlinedButton.icon(
                  onPressed: _deleting ? null : _deletePatient,
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                  icon: _deleting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.danger),
                        )
                      : const Icon(Icons.delete),
                  label: Text(_deleting ? 'Deleting…' : 'Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
