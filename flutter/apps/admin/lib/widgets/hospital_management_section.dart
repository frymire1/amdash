import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/admin_service.dart';
import 'admin_page.dart';

/// Hospital management, embedded in [OrganizationSettingsScreen] rather
/// than living on its own route/tab — hospitals are an org-level setting
/// like data retention, not a separate management domain the way users
/// are. Was previously `HospitalManagementScreen`, a full `AdminPage` of
/// its own; now just the two cards (add form + table), title-less so the
/// enclosing settings page supplies its own section heading.
class HospitalManagementSection extends ConsumerStatefulWidget {
  const HospitalManagementSection({super.key});

  @override
  ConsumerState<HospitalManagementSection> createState() => _HospitalManagementSectionState();
}

class _HospitalManagementSectionState extends ConsumerState<HospitalManagementSection> {
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  bool _creating = false;
  String? _createMessage;
  bool _createIsError = false;

  String? _deletingId;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _createHospital() async {
    final name = _nameController.text.trim();
    final address = _addressController.text.trim();
    if (name.isEmpty || address.isEmpty) return;

    setState(() {
      _creating = true;
      _createMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).createHospital(name: name, address: address);
      _nameController.clear();
      _addressController.clear();
      if (mounted) {
        setState(() {
          _createMessage = 'Hospital added.';
          _createIsError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _createMessage = _errorMessage(error, 'Failed to add hospital. Please check the address and try again.');
          _createIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _deleteHospital(String id) async {
    setState(() => _deletingId = id);
    try {
      await ref.read(adminServiceProvider).deleteHospital(id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorMessage(error, 'Failed to delete hospital.'))),
        );
      }
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
  }

  String _errorMessage(Object error, String fallback) {
    final text = error.toString();
    return text.contains('message:') || text.length < 120 ? text : fallback;
  }

  @override
  Widget build(BuildContext context) {
    final hospitals = ref.watch(hospitalsProvider).valueOrNull ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Add Hospital', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: 12),
              TextField(
                controller: _addressController,
                decoration: const InputDecoration(
                  labelText: 'Address',
                  hintText: '123 Main St, Toronto, ON',
                ),
              ),
              if (_createMessage != null) FormMessage(text: _createMessage!, isError: _createIsError),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('add_hospital_submit'),
                onPressed: _creating ? null : _createHospital,
                child: _creating
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Add Hospital'),
              ),
            ],
          ),
        ),
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Hospitals', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              if (hospitals.isEmpty)
                const EmptyState(title: 'No hospitals yet', subtitle: 'Add a hospital above to get started')
              else
                Table(
                  columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(3), 2: FixedColumnWidth(56)},
                  border: TableBorder(horizontalInside: BorderSide(color: context.palette.border)),
                  children: [
                    TableRow(
                      children: [
                        _headerCell('Name'),
                        _headerCell('Address'),
                        const SizedBox.shrink(),
                      ],
                    ),
                    for (final hospital in hospitals)
                      TableRow(
                        children: [
                          _cell(hospital.name),
                          _cell(hospital.address),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: _deletingId == hospital.id
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : IconButton(
                                    key: Key('delete_hospital_${hospital.name}'),
                                    onPressed: () => _deleteHospital(hospital.id),
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: 'Delete',
                                  ),
                          ),
                        ],
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _headerCell(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(text, style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurfaceVariant)),
  );

  Widget _cell(String text) => Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(text));
}
