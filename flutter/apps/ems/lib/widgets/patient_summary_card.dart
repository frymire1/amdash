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

    await ref.read(emsTrackingProvider.notifier).stopTracking(widget.uploaded.id);

    setState(() {
      _deleting = true;
      _deleteError = null;
    });

    try {
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

    await ref.read(emsTrackingProvider.notifier).stopTracking(widget.uploaded.id);

    setState(() {
      _completing = true;
      _completeError = null;
    });

    try {
      await ref.read(patientUploadServiceProvider).completeTransport(widget.uploaded.id);
    } catch (error) {
      if (mounted) setState(() => _completeError = 'Failed to complete transport. Please try again.');
    } finally {
      if (mounted) setState(() => _completing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final patient = widget.uploaded.patient;
    final isTracking = ref.watch(emsTrackingProvider).contains(widget.uploaded.id);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: StatusPill(
                kind: isTracking ? StatusPillKind.active : StatusPillKind.critical,
                label: isTracking ? 'Tracking Online' : 'Tracking Offline',
                pulsing: isTracking,
              ),
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
                  icon: _completing
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check_circle),
                  label: Text(_completing ? 'Completing…' : 'Complete Transport'),
                ),
                OutlinedButton.icon(
                  onPressed: _deleting ? null : _deletePatient,
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                  icon: _deleting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
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
