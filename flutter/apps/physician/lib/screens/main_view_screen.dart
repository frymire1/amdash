import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/patient_service.dart';
import '../widgets/patient_list.dart';
import '../widgets/patient_viewer.dart';

/// Mirrors `main-view.component.ts`/`.html`: patient list + patient viewer,
/// side-by-side on wide screens, toggled between on narrow ones. The
/// Angular version renders two separate `<app-patient-list>` instances
/// (one per breakpoint) purely for CSS responsiveness — flattened here into
/// one shared list widget behind a `LayoutBuilder`, avoiding a second live
/// Firestore-backed widget subtree for the same data.
class MainViewScreen extends ConsumerStatefulWidget {
  const MainViewScreen({super.key});

  @override
  ConsumerState<MainViewScreen> createState() => _MainViewScreenState();
}

class _MainViewScreenState extends ConsumerState<MainViewScreen> {
  // Only the id is held in state — the actual Patient object is re-looked-up
  // from the live physicianPatientsProvider list on every build (below).
  // Holding a full Patient snapshot here instead (as this used to) meant the
  // viewer pane silently froze on whatever the patient looked like at
  // selection time: PatientList's cards update live because they watch the
  // provider directly, but a snapshot handed off once via onSelected never
  // sees any of that provider's later emissions — confirmed via a real
  // report that editing a viewed patient updated their list card but not
  // the open detail pane.
  String? _selectedPatientId;
  bool _showListOnMobile = false;

  void _onSelected(Patient patient) {
    setState(() {
      _selectedPatientId = patient.id;
      _showListOnMobile = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final patients = ref.watch(physicianPatientsProvider).valueOrNull ?? const [];
    Patient? selectedPatient;
    for (final patient in patients) {
      if (patient.id == _selectedPatientId) {
        selectedPatient = patient;
        break;
      }
    }

    // No Scaffold/NavBar of its own — this screen lives inside the app's
    // ShellRoute now, which owns those.
    return LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop = constraints.maxWidth >= 768;

          if (isDesktop) {
            return Row(
              children: [
                SizedBox(
                  width: constraints.maxWidth * 0.35,
                  child: PatientList(onSelected: _onSelected),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: PatientViewer(
                    key: ValueKey(_selectedPatientId),
                    patient: selectedPatient,
                  ),
                ),
              ],
            );
          }

          // Also falls back to the list when nothing is selected yet — on
          // first load there's no patient to view, so land on the list
          // directly instead of an empty PatientViewer with a button to get
          // there. The button (below) still shows once a patient is picked.
          if (_showListOnMobile || selectedPatient == null) {
            return PatientList(onSelected: _onSelected);
          }

          // Reached only once a patient is selected (see the fallback
          // above). The "Patient List" button used to float over
          // PatientViewer via a Stack, which covered the patient's name —
          // now passed in as PatientViewer's `leading`, so it sits in its
          // own space above the name and scrolls away with the rest of the
          // content instead.
          return PatientViewer(
            key: ValueKey(_selectedPatientId),
            patient: selectedPatient,
            leading: FilledButton.icon(
              onPressed: () => setState(() => _showListOnMobile = true),
              icon: const Icon(Icons.list),
              label: const Text('Patient List'),
            ),
          );
        },
      );
  }
}
