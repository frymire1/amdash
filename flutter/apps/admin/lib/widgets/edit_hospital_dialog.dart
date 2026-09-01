import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/admin_service.dart';
import 'admin_page.dart';

/// Opens the per-hospital edit dialog — name/address, re-geocoded
/// server-side if the address changes (see `updateHospital` in
/// `functions/src/admin.ts`). No `onChanged` callback needed here, unlike
/// [showEditUserDialog]: `hospitalsProvider` is a live Firestore stream, so
/// the table behind this dialog updates itself once the write lands.
Future<void> showEditHospitalDialog(BuildContext context, Hospital hospital) {
  return showDialog<void>(
    context: context,
    builder: (context) => EditHospitalDialog(hospital: hospital),
  );
}

class EditHospitalDialog extends ConsumerStatefulWidget {
  const EditHospitalDialog({required this.hospital, super.key});

  final Hospital hospital;

  @override
  ConsumerState<EditHospitalDialog> createState() => _EditHospitalDialogState();
}

class _EditHospitalDialogState extends ConsumerState<EditHospitalDialog> {
  late final _nameController = TextEditingController(text: widget.hospital.name);
  late final _addressController = TextEditingController(text: widget.hospital.address);

  bool _saving = false;
  String? _message;
  bool _isError = false;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  String _errorMessage(Object error, String fallback) {
    final text = error.toString();
    return text.contains('message:') || text.length < 120 ? text : fallback;
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final address = _addressController.text.trim();
    if (name.isEmpty || address.isEmpty) return;

    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await ref.read(adminServiceProvider).updateHospital(
        hospitalId: widget.hospital.id,
        name: name,
        address: address,
      );
      if (mounted) {
        setState(() {
          _message = 'Saved.';
          _isError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = _errorMessage(error, 'Failed to save changes. Please check the address and try again.');
          _isError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Hospital'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            TextField(
              controller: _addressController,
              decoration: const InputDecoration(labelText: 'Address', hintText: '123 Main St, Toronto, ON'),
            ),
            if (_message != null) FormMessage(text: _message!, isError: _isError),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        FilledButton(
          key: const Key('save_hospital_button'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save Changes'),
        ),
      ],
    );
  }
}
