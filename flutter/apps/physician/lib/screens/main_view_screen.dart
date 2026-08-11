import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';

import '../widgets/patient_list.dart';
import '../widgets/patient_viewer.dart';

/// Mirrors `main-view.component.ts`/`.html`: patient list + patient viewer,
/// side-by-side on wide screens, toggled between on narrow ones. The
/// Angular version renders two separate `<app-patient-list>` instances
/// (one per breakpoint) purely for CSS responsiveness — flattened here into
/// one shared list widget behind a `LayoutBuilder`, avoiding a second live
/// Firestore-backed widget subtree for the same data.
class MainViewScreen extends StatefulWidget {
  const MainViewScreen({super.key});

  @override
  State<MainViewScreen> createState() => _MainViewScreenState();
}

class _MainViewScreenState extends State<MainViewScreen> {
  Patient? _selectedPatient;
  bool _showListOnMobile = false;

  void _onSelected(Patient patient) {
    setState(() {
      _selectedPatient = patient;
      _showListOnMobile = false;
    });
  }

  @override
  Widget build(BuildContext context) {
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
                    key: ValueKey(_selectedPatient?.id),
                    patient: _selectedPatient,
                  ),
                ),
              ],
            );
          }

          if (_showListOnMobile) {
            return PatientList(onSelected: _onSelected);
          }

          // The "Patient List" button used to float over PatientViewer via a
          // Stack, which covered the patient's name — now passed in as
          // PatientViewer's `leading`, so it sits in its own space above the
          // name and scrolls away with the rest of the content instead.
          return PatientViewer(
            key: ValueKey(_selectedPatient?.id),
            patient: _selectedPatient,
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
