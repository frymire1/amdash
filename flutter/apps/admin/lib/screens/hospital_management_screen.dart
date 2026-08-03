import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/admin_service.dart';
import '../widgets/admin_page.dart';

/// Mirrors `hospital-management.component.ts`/`.html`: an "Add Hospital"
/// form (name + free-text address — geocoding is fully server-side inside
/// `createHospital`, lat/lng are never entered or shown here) and a table
/// with per-row delete. The list itself is [hospitalsProvider] from
/// `amdash_core` — a live Firestore query, not a Cloud Function — so a
/// created/deleted hospital appears without any manual refresh.
class HospitalManagementScreen extends ConsumerStatefulWidget {
  const HospitalManagementScreen({super.key});

  @override
  ConsumerState<HospitalManagementScreen> createState() => _HospitalManagementScreenState();
}

class _HospitalManagementScreenState extends ConsumerState<HospitalManagementScreen> {
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

    return AdminPage(
      children: [
        const Text('Hospital Management', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
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
                Text('No hospitals yet.', style: TextStyle(color: AppColors.slate500))
              else
                Table(
                  columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(3), 2: FixedColumnWidth(56)},
                  border: TableBorder(horizontalInside: BorderSide(color: AppColors.slate200)),
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
    child: Text(text, style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.slate500)),
  );

  Widget _cell(String text) => Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(text));
}
