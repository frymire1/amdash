import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/managed_user.dart';
import '../services/admin_service.dart';
import '../widgets/admin_page.dart';
import '../widgets/edit_user_dialog.dart';

/// Mirrors `user-management.component.ts`/`.html`: an "Add User" form and a
/// table of the org's users. Per-user editing (roles, name, email, account
/// deletion) lives in [showEditUserDialog], opened from each row's Edit
/// button — replaces a separate "Assign a Role" card that required
/// re-typing the target's email by hand. List comes from
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

  final _searchController = TextEditingController();
  String _searchQuery = '';
  UserRole? _roleFilter;

  @override
  void initState() {
    super.initState();
    _refreshUsers();
    _searchController.addListener(() => setState(() => _searchQuery = _searchController.text.trim().toLowerCase()));
  }

  @override
  void dispose() {
    _createEmailController.dispose();
    _createFirstNameController.dispose();
    _createLastNameController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<ManagedUser> _filteredUsers() {
    return _users.where((user) {
      if (_roleFilter != null && !user.role.contains(_roleFilter)) return false;
      if (_searchQuery.isEmpty) return true;
      final haystack = '${user.email} ${user.firstName} ${user.lastName}'.toLowerCase();
      return haystack.contains(_searchQuery);
    }).toList();
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
                const EmptyState(title: 'No users yet', subtitle: 'Add a user above to get started')
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        decoration: const InputDecoration(
                          labelText: 'Search',
                          hintText: 'Name or email',
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      // 160 clipped the "All roles" option's own text —
                      // confirmed via a real overflow.
                      width: 210,
                      child: DropdownButtonFormField<UserRole?>(
                        initialValue: _roleFilter,
                        decoration: const InputDecoration(labelText: 'Role', isDense: true),
                        items: [
                          const DropdownMenuItem(value: null, child: Text('All roles')),
                          for (final role in assignableRoles) DropdownMenuItem(value: role, child: Text(role.wireValue)),
                        ],
                        onChanged: (value) => setState(() => _roleFilter = value),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Builder(
                  builder: (context) {
                    final filtered = _filteredUsers();
                    if (filtered.isEmpty) {
                      return const EmptyState(title: 'No users match this search', graphic: EmptyStateGraphic.chartPulse);
                    }
                    return _UsersTable(
                      users: filtered,
                      onEdit: (user) => showEditUserDialog(context, user, _refreshUsers),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _UsersTable extends StatelessWidget {
  const _UsersTable({required this.users, required this.onEdit});

  final List<ManagedUser> users;
  final void Function(ManagedUser user) onEdit;

  @override
  Widget build(BuildContext context) {
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: FlexColumnWidth(2),
        // 130 clipped the "Suspended" pill's own uppercase, letter-spaced
        // label — confirmed via a real overflow with a suspended user.
        2: FixedColumnWidth(150),
        3: FlexColumnWidth(3),
        4: FixedColumnWidth(56),
      },
      border: TableBorder(horizontalInside: BorderSide(color: context.palette.border)),
      children: [
        TableRow(
          children: [
            _headerCell(context, 'Email'),
            _headerCell(context, 'Name'),
            _headerCell(context, 'Status'),
            _headerCell(context, 'Role'),
            const SizedBox.shrink(),
          ],
        ),
        for (final user in users)
          TableRow(
            children: [
              _cell(user.email),
              _cell('${user.firstName} ${user.lastName}'),
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusPill(
                      kind: user.disabled
                          ? StatusPillKind.critical
                          : (user.hasPassword ? StatusPillKind.active : StatusPillKind.warning),
                      label: user.disabled ? 'Suspended' : (user.hasPassword ? 'Active' : 'Invited'),
                    ),
                    const SizedBox(height: 4),
                    StatusPill(
                      kind: user.mfaEnrolled ? StatusPillKind.active : StatusPillKind.warning,
                      label: user.mfaEnrolled ? 'MFA on' : 'MFA off',
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: user.role.isEmpty
                      ? [_roleChip(context, label: 'Unassigned', unassigned: true)]
                      : [for (final role in user.role) _roleChip(context, label: role.wireValue)],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: IconButton(
                  key: Key('edit_user_${user.email}'),
                  onPressed: () => onEdit(user),
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit',
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _headerCell(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
    child: Text(text, style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurfaceVariant)),
  );

  Widget _cell(String text) => Padding(padding: const EdgeInsets.fromLTRB(0, 8, 12, 8), child: Text(text));

  // Read-only now — role assignment/removal moved into the Edit User
  // dialog (see edit_user_dialog.dart), which acts on one user at a time
  // instead of requiring the admin to retype an email into a separate form.
  Widget _roleChip(BuildContext context, {required String label, bool unassigned = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    final accent = colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: unassigned ? colorScheme.surfaceContainerHighest : accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: unassigned ? null : Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Text(label, style: TextStyle(color: unassigned ? colorScheme.onSurfaceVariant : accent)),
    );
  }
}
