import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/admin_service.dart';
import '../services/organization_service.dart';
import '../widgets/admin_page.dart';
import '../widgets/hospital_management_section.dart';

/// Mirrors `organization-settings.component.ts`/`.html`: a single
/// retention toggle for the caller's own org, bound to the live Firestore
/// value ([ownOrganizationProvider]) rather than local optimistic state —
/// on success the listener reflects the confirmed write on its own; on
/// failure there's nothing to roll back, so no local state to revert
/// either. `retainAllData` semantics: default/missing/false → completed
/// transports (+ their emsLocations doc) are deleted 48h after
/// completion by the daily cleanup job; true → this org's completed
/// patients are skipped by that job entirely.
///
/// Also hosts hospital management ([HospitalManagementSection]) — folded
/// in here rather than kept on its own route/tab, since hospitals are an
/// org-level setting like retention, not a separate management domain the
/// way users are.
class OrganizationSettingsScreen extends ConsumerStatefulWidget {
  const OrganizationSettingsScreen({super.key});

  @override
  ConsumerState<OrganizationSettingsScreen> createState() => _OrganizationSettingsScreenState();
}

class _OrganizationSettingsScreenState extends ConsumerState<OrganizationSettingsScreen> {
  bool _saving = false;
  String? _errorMessage;

  Future<void> _setRetention(bool value) async {
    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).setOrganizationRetention(value);
    } catch (error) {
      if (mounted) setState(() => _errorMessage = 'Failed to save. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final organization = ref.watch(ownOrganizationProvider).valueOrNull;
    final retainAllData = organization?.retainAllData ?? false;

    return AdminPage(
      children: [
        const Text('Organization Settings', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Data Retention', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'By default, completed transports and their location history are deleted 48 hours after '
                'completion. Turn this on to keep them indefinitely.',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Switch(
                    value: retainAllData,
                    onChanged: _saving || organization == null ? null : _setRetention,
                  ),
                  const SizedBox(width: 8),
                  Text(retainAllData ? 'Retaining all data' : 'Auto-deleting after 48 hours'),
                  if (_saving) ...[
                    const SizedBox(width: 12),
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ],
              ),
              if (_errorMessage != null) FormMessage(text: _errorMessage!, isError: true),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Text('Hospitals', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        const HospitalManagementSection(),
      ],
    );
  }
}
