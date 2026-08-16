import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/admin_service.dart';
import '../services/organization_service.dart';
import '../widgets/admin_page.dart';

/// Mirrors `organization-management.component.ts`/`.html` — super-admin
/// only (route-gated). Org + its first admin are always created together
/// atomically via `createOrganization`; there's deliberately no
/// "create an empty organization" path. The list is [organizationsProvider]
/// — unconstrained across every org, only legal for a super-admin.
class OrganizationManagementScreen extends ConsumerStatefulWidget {
  const OrganizationManagementScreen({super.key});

  @override
  ConsumerState<OrganizationManagementScreen> createState() => _OrganizationManagementScreenState();
}

class _OrganizationManagementScreenState extends ConsumerState<OrganizationManagementScreen> {
  final _orgNameController = TextEditingController();
  final _adminEmailController = TextEditingController();
  final _adminFirstNameController = TextEditingController();
  final _adminLastNameController = TextEditingController();
  bool _creating = false;
  String? _message;
  bool _isError = false;

  @override
  void dispose() {
    _orgNameController.dispose();
    _adminEmailController.dispose();
    _adminFirstNameController.dispose();
    _adminLastNameController.dispose();
    super.dispose();
  }

  Future<void> _createOrganization() async {
    final organizationName = _orgNameController.text.trim();
    final adminEmail = _adminEmailController.text.trim();
    final adminFirstName = _adminFirstNameController.text.trim();
    final adminLastName = _adminLastNameController.text.trim();
    if (organizationName.isEmpty || adminEmail.isEmpty || adminFirstName.isEmpty || adminLastName.isEmpty) {
      return;
    }

    setState(() {
      _creating = true;
      _message = null;
    });
    try {
      await ref.read(adminServiceProvider).createOrganization(
        organizationName: organizationName,
        adminEmail: adminEmail,
        adminFirstName: adminFirstName,
        adminLastName: adminLastName,
      );
      _orgNameController.clear();
      _adminEmailController.clear();
      _adminFirstNameController.clear();
      _adminLastNameController.clear();
      if (mounted) {
        setState(() {
          _message = 'Organization created.';
          _isError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = _errorMessage(error, 'Failed to create organization.');
          _isError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  String _errorMessage(Object error, String fallback) {
    final text = error.toString();
    return text.contains('message:') || text.length < 120 ? text : fallback;
  }

  @override
  Widget build(BuildContext context) {
    final organizations = ref.watch(organizationsProvider).valueOrNull ?? const [];

    return AdminPage(
      children: [
        const Text('Organization Management', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Create Organization', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              TextField(
                controller: _orgNameController,
                decoration: const InputDecoration(labelText: 'Organization Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _adminEmailController,
                decoration: const InputDecoration(labelText: 'Admin Email'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _adminFirstNameController,
                decoration: const InputDecoration(labelText: 'Admin First Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _adminLastNameController,
                decoration: const InputDecoration(labelText: 'Admin Last Name'),
              ),
              if (_message != null) FormMessage(text: _message!, isError: _isError),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _creating ? null : _createOrganization,
                child: _creating
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Create Organization'),
              ),
            ],
          ),
        ),
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Organizations', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              if (organizations.isEmpty)
                const EmptyState(title: 'No organizations yet', subtitle: 'Create one above to get started')
              else
                Table(
                  border: TableBorder(horizontalInside: BorderSide(color: context.palette.border)),
                  children: [
                    TableRow(children: [_headerCell('Name')]),
                    for (final org in organizations) TableRow(children: [_cell(org.name)]),
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
