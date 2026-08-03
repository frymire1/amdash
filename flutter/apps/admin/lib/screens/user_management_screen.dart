import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/managed_user.dart';
import '../services/admin_service.dart';
import '../widgets/admin_page.dart';

/// Mirrors `user-management.component.ts`/`.html`: an "Add User" form, a
/// separate "Assign a Role" form, and a table of the org's users with
/// removable role chips (multi-role — `setUserRole`/`removeUserRole`
/// arrayUnion/arrayRemove a single role at a time; there's no multi-select
/// control, chips are the whole UI for it). List comes from
/// `listUsersWithRoles` (a Cloud Function, not a live Firestore query —
/// regular admins have no legal direct `list` on `users`), loaded once and
/// refreshed manually or after a mutation, not live.
class UserManagementScreen extends ConsumerStatefulWidget {
  const UserManagementScreen({super.key});

  @override
  ConsumerState<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends ConsumerState<UserManagementScreen> {
  List<ManagedUser> _users = [];
  bool _loadingUsers = true;
  String? _listError;

  final _createEmailController = TextEditingController();
  final _createFirstNameController = TextEditingController();
  final _createLastNameController = TextEditingController();
  UserRole? _createRole;
  bool _creating = false;
  String? _createMessage;
  bool _createIsError = false;

  final _assignEmailController = TextEditingController();
  UserRole? _assignRole;
  bool _assigning = false;
  String? _assignMessage;
  bool _assignIsError = false;

  String? _removingRoleKey;

  @override
  void initState() {
    super.initState();
    _refreshUsers();
  }

  @override
  void dispose() {
    _createEmailController.dispose();
    _createFirstNameController.dispose();
    _createLastNameController.dispose();
    _assignEmailController.dispose();
    super.dispose();
  }

  // Every setState below an `await` is guarded with `mounted` — this
  // screen can be disposed mid-request (e.g. the `/` landing route builds
  // a screen briefly while the profile is still loading, then navigates
  // onward once it resolves), and an unguarded setState on a disposed
  // State throws "setState() called after dispose()".
  Future<void> _refreshUsers() async {
    setState(() {
      _loadingUsers = true;
      _listError = null;
    });
    try {
      final users = await ref.read(adminServiceProvider).listUsersWithRoles();
      if (mounted) setState(() => _users = users);
    } catch (error) {
      if (mounted) setState(() => _listError = 'Failed to load users. Please try again.');
    } finally {
      if (mounted) setState(() => _loadingUsers = false);
    }
  }

  Future<void> _createUser() async {
    final email = _createEmailController.text.trim();
    final firstName = _createFirstNameController.text.trim();
    final lastName = _createLastNameController.text.trim();
    final role = _createRole;
    if (email.isEmpty || firstName.isEmpty || lastName.isEmpty || role == null) return;

    setState(() {
      _creating = true;
      _createMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).createUser(
        email: email,
        firstName: firstName,
        lastName: lastName,
        role: role,
      );
      _createEmailController.clear();
      _createFirstNameController.clear();
      _createLastNameController.clear();
      if (mounted) {
        setState(() {
          _createRole = null;
          _createMessage = 'User created.';
          _createIsError = false;
        });
      }
      await _refreshUsers();
    } catch (error) {
      if (mounted) {
        setState(() {
          _createMessage = _errorMessage(error, 'Failed to create user.');
          _createIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _assignRoleSubmit() async {
    final email = _assignEmailController.text.trim();
    final role = _assignRole;
    if (email.isEmpty || role == null) return;

    setState(() {
      _assigning = true;
      _assignMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).setUserRole(email: email, role: role);
      _assignEmailController.clear();
      if (mounted) {
        setState(() {
          _assignRole = null;
          _assignMessage = 'Role assigned.';
          _assignIsError = false;
        });
      }
      await _refreshUsers();
    } catch (error) {
      if (mounted) {
        setState(() {
          _assignMessage = _errorMessage(error, 'Failed to assign role.');
          _assignIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _assigning = false);
    }
  }

  Future<void> _removeRole(ManagedUser user, UserRole role) async {
    final key = '${user.uid}:${role.wireValue}';
    setState(() => _removingRoleKey = key);
    try {
      await ref.read(adminServiceProvider).removeUserRole(email: user.email, role: role);
      await _refreshUsers();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorMessage(error, 'Failed to remove role.'))),
        );
      }
    } finally {
      if (mounted) setState(() => _removingRoleKey = null);
    }
  }

  String _errorMessage(Object error, String fallback) {
    final text = error.toString();
    return text.contains('message:') || text.length < 120 ? text : fallback;
  }

  @override
  Widget build(BuildContext context) {
    return AdminPage(
      children: [
        const Text('User Management', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Add User', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              TextField(controller: _createEmailController, decoration: const InputDecoration(labelText: 'Email')),
              const SizedBox(height: 12),
              TextField(
                controller: _createFirstNameController,
                decoration: const InputDecoration(labelText: 'First Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _createLastNameController,
                decoration: const InputDecoration(labelText: 'Last Name'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<UserRole>(
                key: const Key('add_user_role_dropdown'),
                initialValue: _createRole,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [
                  for (final role in assignableRoles)
                    DropdownMenuItem(
                      value: role,
                      child: KeyedSubtree(
                        key: Key('add_user_role_option_${role.wireValue}'),
                        child: Text(role.wireValue),
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _createRole = value),
              ),
              if (_createMessage != null) FormMessage(text: _createMessage!, isError: _createIsError),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('add_user_submit'),
                onPressed: _creating ? null : _createUser,
                child: _creating
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Add User'),
              ),
            ],
          ),
        ),
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Assign a Role', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              TextField(controller: _assignEmailController, decoration: const InputDecoration(labelText: 'Email')),
              const SizedBox(height: 12),
              DropdownButtonFormField<UserRole>(
                key: const Key('assign_role_dropdown'),
                initialValue: _assignRole,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [
                  for (final role in assignableRoles)
                    DropdownMenuItem(
                      value: role,
                      child: KeyedSubtree(
                        key: Key('assign_role_option_${role.wireValue}'),
                        child: Text(role.wireValue),
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _assignRole = value),
              ),
              if (_assignMessage != null) FormMessage(text: _assignMessage!, isError: _assignIsError),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('assign_role_submit'),
                onPressed: _assigning ? null : _assignRoleSubmit,
                child: _assigning
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Assign Role'),
              ),
            ],
          ),
        ),
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Users', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                  IconButton(
                    onPressed: _loadingUsers ? null : _refreshUsers,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh',
                  ),
                ],
              ),
              if (_loadingUsers)
                const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
              else if (_listError != null)
                FormMessage(text: _listError!, isError: true)
              else if (_users.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('No users yet.', style: TextStyle(color: AppColors.slate500)),
                )
              else
                _UsersTable(users: _users, removingRoleKey: _removingRoleKey, onRemoveRole: _removeRole),
            ],
          ),
        ),
      ],
    );
  }
}

class _UsersTable extends StatelessWidget {
  const _UsersTable({required this.users, required this.removingRoleKey, required this.onRemoveRole});

  final List<ManagedUser> users;
  final String? removingRoleKey;
  final void Function(ManagedUser user, UserRole role) onRemoveRole;

  @override
  Widget build(BuildContext context) {
    return Table(
      columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(2), 2: FlexColumnWidth(3)},
      border: TableBorder(horizontalInside: BorderSide(color: AppColors.slate200)),
      children: [
        TableRow(
          children: [
            _headerCell('Email'),
            _headerCell('Name'),
            _headerCell('Role'),
          ],
        ),
        for (final user in users)
          TableRow(
            children: [
              _cell(user.email),
              _cell('${user.firstName} ${user.lastName}'),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: user.role.isEmpty
                      ? [_roleChip(label: 'Unassigned', unassigned: true)]
                      : [
                          for (final role in user.role)
                            _roleChip(
                              label: role.wireValue,
                              removing: removingRoleKey == '${user.uid}:${role.wireValue}',
                              onRemove: () => onRemoveRole(user, role),
                            ),
                        ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _headerCell(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(text, style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.slate500)),
  );

  Widget _cell(String text) => Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(text));

  Widget _roleChip({required String label, bool unassigned = false, bool removing = false, VoidCallback? onRemove}) {
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: unassigned ? AppColors.slate100 : const Color(0xFFDBEAFE),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: unassigned ? AppColors.slate500 : const Color(0xFF1D4ED8))),
          if (!unassigned) ...[
            const SizedBox(width: 2),
            if (removing)
              const Padding(
                padding: EdgeInsets.all(4),
                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              InkWell(
                onTap: onRemove,
                customBorder: const CircleBorder(),
                child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.close, size: 14)),
              ),
          ],
        ],
      ),
    );
  }
}
