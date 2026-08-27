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
  bool _exportingFhir = false;
  String? _deleteError;
  String? _completeError;
  String? _exportError;
  String? _exportSuccessMessage;

  Future<void> _deletePatient() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete patient?',
      message: 'Delete ${widget.uploaded.patient.name.display()}? This cannot be undone.',
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
    // organization is read up front so the disclosure about an automatic
    // export can actually be accurate in this one dialog — there's no
    // second confirmation for the export itself (see below for why).
    final organization = await ref.read(ownOrganizationProvider.future);
    final willAutoExport = organization?.fhirExportEnabled == true;
    if (!mounted) return;

    final confirmed = await showConfirmDialog(
      context,
      title: 'Complete transport?',
      message: willAutoExport
          ? "Mark ${widget.uploaded.patient.name.display()}'s transport as complete? Live tracking will stop and it "
                "will no longer appear as active. Its record will then be exported as FHIR automatically — this "
                "downloads an unencrypted file containing this patient's information to your device, and AmDash's "
                "own access controls no longer apply to it once saved."
          : "Mark ${widget.uploaded.patient.name.display()}'s transport as complete? Live tracking will stop and it "
                'will no longer appear as active.',
      confirmLabel: 'Complete Transport',
    );
    if (!confirmed || !mounted) return;

    // Captured now, not read again later: this card drops out of
    // HomeScreen's active-only patient list the instant completion lands,
    // so `widget`/`context` can become unusable partway through this
    // method (and, before home_screen.dart keyed each card by patient id,
    // silently started referring to a *different* patient instead of
    // simply going away — confirmed for real via a genuine Patrol e2e
    // failure where a confirmed-complete write was followed by an export
    // attempt that kept failing "must be marked complete", because the
    // widget had been reused for a still-active patient by then). The
    // container itself is scoped to the app's ProviderScope, not this
    // card, so reads through it below stay valid regardless of what
    // happens to this widget from here on.
    final container = ProviderScope.containerOf(context, listen: false);
    final patientId = widget.uploaded.id;
    final patientDisplayName = widget.uploaded.patient.name.display();

    setState(() {
      _completing = true;
      _completeError = null;
    });

    // completeTransportConfirmed (not the plain completeTransport) —
    // see its own doc comment: this account's first-ever direct
    // Firestore write can silently miss the wire even though its own
    // Future resolves without error, so this retries and confirms via a
    // real server round trip rather than trusting that Future alone.
    bool completedOk;
    try {
      await container.read(emsTrackingProvider.notifier).stopTracking(patientId);
      await container.read(patientUploadServiceProvider).completeTransportConfirmed(patientId);
      completedOk = true;
    } catch (error) {
      completedOk = false;
      if (mounted) setState(() => _completeError = 'Failed to complete transport. Please try again.');
    } finally {
      if (mounted) setState(() => _completing = false);
    }
    if (!completedOk || !willAutoExport) return;

    await _autoExportFhir(container, patientId, patientDisplayName);
  }

  // No confirmation dialog of its own — already disclosed as part of
  // "Complete transport?" above, and a second dialog here would need this
  // card's own (soon-to-be-gone) context to anchor it, right when this
  // card is guaranteed to be disappearing from the active list. Runs
  // automatically instead, using [container] rather than this State's own
  // `ref`, so it doesn't matter whether this widget is still mounted by
  // the time it resolves — only the setState calls below (best-effort UI
  // feedback for the rare case this card is somehow still visible) are
  // guarded on that.
  Future<void> _autoExportFhir(ProviderContainer container, String patientId, String patientDisplayName) async {
    if (mounted) {
      setState(() {
        _exportingFhir = true;
        _exportError = null;
        _exportSuccessMessage = null;
      });
    }

    try {
      final result = await exportPatientFhirBundle(container.read(fhirExportFunctionsProvider), patientId);
      // Pulled straight out of the callable's own real response, not
      // re-derived from local form state — this is what proves the
      // exported file's vitals actually match what's in the app, not
      // just that the export call didn't throw. (Also captured in
      // amdash_core's debugLastExportResult — see its own doc comment —
      // for a test to check directly, since this card may well be gone
      // from the tree by the time any of this resolves.)
      final heartRate = latestObservationValue(result.bundle, loincHeartRate);
      if (mounted) {
        setState(
          () => _exportSuccessMessage = heartRate == null
              ? '$patientDisplayName: FHIR record exported.'
              : '$patientDisplayName: FHIR record exported (heart rate: ${heartRate.toStringAsFixed(0)} bpm).',
        );
      }
    } on FhirExportException catch (error) {
      if (mounted) setState(() => _exportError = error.message);
    } catch (error) {
      if (mounted) setState(() => _exportError = "Couldn't export this patient's FHIR record. Please try again.");
    } finally {
      if (mounted) setState(() => _exportingFhir = false);
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            // Tap anywhere on the summary to open the read-only patient
            // viewer. The buttons below live outside this InkWell entirely
            // — a sibling, not a nested tap target inside it — so there's
            // no ambiguity about a tap on Edit/Complete/Delete also
            // triggering this navigation.
            onTap: () => context.push('/patient/${widget.uploaded.id}'),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.md)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _trackingPill(isTracking, health),
                  ),
                  const SizedBox(height: 8),
                  PatientFieldText(patient.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  PatientFieldText(
                    patient.healthcareNumber,
                    prefix: 'Healthcare #',
                    style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(patient.gender),
                      const SizedBox(width: 12),
                      Text('${patient.age} yrs'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  PatientVitalsChips(vitals: patient.vitals),
                  if (_deleteError != null) ...[
                    const SizedBox(height: 8),
                    Text(_deleteError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  if (_completeError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _completeError!,
                      key: const Key('complete_transport_error'),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  // No button to show a spinner on anymore — the export is
                  // chained straight onto Complete Transport's own confirm
                  // dialog (see _completeTransport's doc comment on why), so
                  // this inline row is the only feedback that anything is
                  // happening between confirming and the success/error text
                  // below landing.
                  if (_exportingFhir) ...[
                    const SizedBox(height: 8),
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 8),
                        Text('Exporting FHIR record…'),
                      ],
                    ),
                  ],
                  if (_exportError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _exportError!,
                      key: const Key('fhir_export_error'),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  if (_exportSuccessMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _exportSuccessMessage!,
                      key: const Key('fhir_export_success'),
                      style: const TextStyle(color: AppColors.success),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Wrap(
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
          ),
        ],
      ),
    );
  }
}
