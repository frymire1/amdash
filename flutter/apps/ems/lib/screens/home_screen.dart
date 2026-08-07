import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/patient_session_service.dart';
import '../widgets/patient_summary_card.dart';

/// Mirrors `home.component.ts`/`.html`.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uploadedPatients = ref.watch(uploadedPatientsProvider);

    return Scaffold(
      appBar: const NavBar(),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              // Center + ConstrainedBox — same pattern as
              // patient_upload_screen.dart's form, so the dashboard's list
              // and the upload form line up at the same width instead of
              // the list stretching edge-to-edge on wide screens.
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(
                        width: double.infinity,
                        child: Text(
                          'EMS Dashboard',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const SizedBox(
                        width: double.infinity,
                        child: Text(
                          'Upload patient information to hand off to the receiving physician.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: FilledButton.icon(
                          onPressed: () => context.push('/upload'),
                          icon: const Icon(Icons.person_add),
                          label: const Text('Add Patient'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      uploadedPatients.when(
                        // .stretch so each PatientSummaryCard fills the same
                        // 720px width as patient_upload_screen.dart's form
                        // sections, instead of shrink-wrapping to its own
                        // content width under the outer Column's .start.
                        data: (patients) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [for (final uploaded in patients) PatientSummaryCard(uploaded: uploaded)],
                        ),
                        loading: () => const Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                        error: (error, stackTrace) => Text(
                          'Failed to load patients: $error',
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
