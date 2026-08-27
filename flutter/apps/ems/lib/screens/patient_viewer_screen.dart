import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/patient_session_service.dart';

/// Read-only patient detail screen — EMS previously had no way to review a
/// patient's full record short of opening the edit form
/// ([PatientUploadScreen]), a much heavier, easier-to-misclick surface for
/// "I just want to look." Reuses the same info/vitals/treatment/notes cards
/// as physician's `PatientViewer` (see amdash_core's
/// `patient_detail_cards.dart`) — deliberately skips physician's live-map/
/// Directions card, which is built for someone remotely tracking the
/// ambulance. EMS is the crew *in* it; they already know where they are and
/// have their own real turn-by-turn navigation running, so an in-app map of
/// their own vehicle would be redundant, not useful.
class PatientViewerScreen extends ConsumerWidget {
  const PatientViewerScreen({required this.patientId, super.key});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patientsAsync = ref.watch(uploadedPatientsProvider);
    final patients = patientsAsync.valueOrNull;
    final patient = patients == null ? null : findUploadedPatient(patients, patientId)?.patient;
    // isLoading (not just "no value yet") is the reliable "still resolving"
    // signal — see patient_session_service.dart's own comment on why
    // hasValue/valueOrNull alone can't be trusted mid-recomputation. Once
    // it's settled, a patient not found here means either a bad id or (more
    // likely) this patient completed/was deleted after this screen was
    // opened — uploadedPatientsProvider only ever lists *active* patients.
    final stillLoading = patientsAsync.isLoading && patients == null;

    // No Scaffold/NavBar of its own — this screen lives inside the app's
    // ShellRoute, which owns those. NavBar has no back button by design, so
    // this provides its own way back to the dashboard, same as
    // PatientUploadScreen.
    return Column(
      children: [
        const OfflineBanner(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back),
                          tooltip: 'Back',
                          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
                        ),
                        const Expanded(
                          child: Text(
                            'Patient Details',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                          ),
                        ),
                        // Balances the leading IconButton's width so the
                        // title is actually centered, not just centered
                        // within the remaining space after it.
                        const SizedBox(width: 48),
                      ],
                    ),
                    const SizedBox(height: 20),
                    if (stillLoading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (patient == null)
                      const EmptyState(
                        graphic: EmptyStateGraphic.chartPulse,
                        title: 'This patient is no longer available',
                        subtitle: 'It may have been completed or removed.',
                      )
                    else ...[
                      PatientFieldText(
                        patient.name,
                        notAddedText: 'Not added yet',
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
                        notAddedText: 'Not added yet',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 16),
                      PatientInfoCard(
                        title: 'Destination Hospital',
                        rows: [PatientInfoChip('Destination', patient.destination)],
                      ),
                      const SizedBox(height: 12),
                      PatientVitalsCard(patient: patient),
                      const SizedBox(height: 12),
                      PatientTreatmentCard(patient: patient),
                      if (isProvidedValue(patient.notes)) ...[
                        const SizedBox(height: 12),
                        PatientTextCard(title: 'Patient Notes', text: patient.notes!),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
