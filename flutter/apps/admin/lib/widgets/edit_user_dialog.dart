import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/managed_user.dart';
import '../services/admin_service.dart';
import 'admin_page.dart';

/// Opens the per-user edit dialog — name/email, role assignment, and
/// account deletion, all scoped to the one user whose row was tapped.
/// Replaces the old standalone "Assign a Role" card, which required
/// re-typing the target's email by hand instead of acting on the row
/// directly. `onChanged` re-fetches the users table after any mutation.
Future<void> showEditUserDialog(BuildContext context, ManagedUser user, VoidCallback onChanged) {
  return showDialog<void>(
    context: context,
    builder: (context) => EditUserDialog(user: user, onChanged: onChanged),
  );
}

class EditUserDialog extends ConsumerStatefulWidget {
  const EditUserDialog({required this.user, required this.onChanged, super.key});

  final ManagedUser user;
  final VoidCallback onChanged;

  @override
  ConsumerState<EditUserDialog> createState() => _EditUserDialogState();
}

class _EditUserDialogState extends ConsumerState<EditUserDialog> {
  late final _emailController = TextEditingController(text: widget.user.email);
  late final _firstNameController = TextEditingController(text: widget.user.firstName);
  late final _lastNameController = TextEditingController(text: widget.user.lastName);

  // Local copy so the dialog's role list updates immediately after an
  // add/remove without waiting on the outer table's refresh to round-trip.
  late List<UserRole> _roles = List.of(widget.user.role);
  UserRole? _roleToAdd;

  bool _savingProfile = false;
  String? _profileMessage;
  bool _profileIsError = false;

  bool _savingRole = false;
  String? _roleMessage;
  bool _roleIsError = false;
  String? _removingRole;

  // hasPassword only ever flips once — from a real password-set event,
  // not from anything this dialog does (resendInvite just re-sends the
  // same email) — so it's a plain final copy, unlike _disabled below.
  late final bool _hasPassword = widget.user.hasPassword;
  late bool _disabled = widget.user.disabled;
  bool _togglingDisabled = false;
  bool _resendingInvite = false;
  String? _statusMessage;
  bool _statusIsError = false;

  // Derived server-side (functions/src/admin.ts's listUsersWithRoles) from
  // the real Auth-side enrollment state — resetUserMfa doesn't return an
  // updated value, so this just latches "reset" locally rather than
  // guessing a new enrolled/not-enrolled state; widget.onChanged()
  // refreshes the real value from the table's next fetch.
  late bool _mfaEnrolled = widget.user.mfaEnrolled;
  bool _resettingMfa = false;

  bool _deleting = false;
  String? _deleteError;

  @override
  void dispose() {
    _emailController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  String _errorMessage(Object error, String fallback) {
    final text = error.toString();
    return text.contains('message:') || text.length < 120 ? text : fallback;
  }

  Future<void> _saveProfile() async {
    final email = _emailController.text.trim();
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    if (email.isEmpty || firstName.isEmpty || lastName.isEmpty) return;

    setState(() {
      _savingProfile = true;
      _profileMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).updateUser(
        uid: widget.user.uid,
        email: email,
        firstName: firstName,
        lastName: lastName,
      );
      widget.onChanged();
      if (mounted) {
        setState(() {
          _profileMessage = 'Saved.';
          _profileIsError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _profileMessage = _errorMessage(error, 'Failed to save changes.');
          _profileIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _savingProfile = false);
    }
  }

  // Roles are keyed off the user's *current* email, same as the old
  // top-level Assign a Role form — if an email edit above hasn't been
  // saved yet, this still targets the account by its last-saved email.
  Future<void> _addRole() async {
    final role = _roleToAdd;
    if (role == null) return;

    setState(() {
      _savingRole = true;
      _roleMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).setUserRole(email: widget.user.email, role: role);
      widget.onChanged();
      if (mounted) {
        setState(() {
          _roles = [..._roles, role];
          _roleToAdd = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _roleMessage = _errorMessage(error, 'Failed to assign role.');
          _roleIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _savingRole = false);
    }
  }

  Future<void> _removeRole(UserRole role) async {
    setState(() => _removingRole = role.wireValue);
    try {
      await ref.read(adminServiceProvider).removeUserRole(email: widget.user.email, role: role);
      widget.onChanged();
      if (mounted) setState(() => _roles = _roles.where((r) => r != role).toList());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorMessage(error, 'Failed to remove role.'))),
        );
      }
    } finally {
      if (mounted) setState(() => _removingRole = null);
    }
  }

  Future<void> _toggleDisabled() async {
    final nextDisabled = !_disabled;
    if (nextDisabled) {
      final confirmed = await showConfirmDialog(
        context,
        title: 'Suspend account?',
        message: "${widget.user.firstName} ${widget.user.lastName} won't be able to sign in until reactivated.",
        confirmLabel: 'Suspend',
      );
      if (!confirmed || !mounted) return;
    }

    setState(() {
      _togglingDisabled = true;
      _statusMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).setUserDisabled(uid: widget.user.uid, disabled: nextDisabled);
      widget.onChanged();
      if (mounted) {
        setState(() {
          _disabled = nextDisabled;
          _statusMessage = nextDisabled ? 'Account suspended.' : 'Account reactivated.';
          _statusIsError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = _errorMessage(error, 'Failed to update account status.');
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _togglingDisabled = false);
    }
  }

  Future<void> _resendInvite() async {
    setState(() {
      _resendingInvite = true;
      _statusMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).resendInvite(widget.user.uid);
      if (mounted) {
        setState(() {
          _statusMessage = 'Invite email resent.';
          _statusIsError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = _errorMessage(error, 'Failed to resend invite.');
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _resendingInvite = false);
    }
  }

  Future<void> _resetMfa() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Reset two-step sign-in?',
      message:
          '${widget.user.firstName} ${widget.user.lastName} will be asked to set up two-step sign-in from '
          "scratch the next time they sign in — use this if they've lost their authenticator device.",
      confirmLabel: 'Reset',
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _resettingMfa = true;
      _statusMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).resetUserMfa(widget.user.uid);
      if (mounted) {
        setState(() {
          _mfaEnrolled = false;
          _statusMessage = 'Two-step sign-in reset.';
          _statusIsError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = _errorMessage(error, 'Failed to reset two-step sign-in.');
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _resettingMfa = false);
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete account?',
      message: 'Delete ${widget.user.firstName} ${widget.user.lastName} (${widget.user.email})? This cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _deleting = true;
      _deleteError = null;
    });
    try {
      await ref.read(adminServiceProvider).deleteUser(widget.user.uid);
      widget.onChanged();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _deleteError = _errorMessage(error, 'Failed to delete account.'));
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final remainingRoles = [for (final role in assignableRoles) if (!_roles.contains(role)) role];
    final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;

    return AlertDialog(
      title: const Text('Edit User'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _emailController, decoration: const InputDecoration(labelText: 'Email')),
              const SizedBox(height: 12),
              TextField(controller: _firstNameController, decoration: const InputDecoration(labelText: 'First Name')),
              const SizedBox(height: 12),
              TextField(controller: _lastNameController, decoration: const InputDecoration(labelText: 'Last Name')),
              if (_profileMessage != null) FormMessage(text: _profileMessage!, isError: _profileIsError),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: _savingProfile ? null : _saveProfile,
                  child: _savingProfile
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save Changes'),
                ),
              ),
              const Divider(height: 32),
              const Text('Roles', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _roles.isEmpty
                    ? [Text('No roles assigned.', style: TextStyle(color: onSurfaceVariant))]
                    : [
                        for (final role in _roles)
                          _RoleChip(
                            label: role.wireValue,
                            removing: _removingRole == role.wireValue,
                            onRemove: () => _removeRole(role),
                          ),
                      ],
              ),
              if (remainingRoles.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<UserRole>(
                        key: const Key('edit_role_dropdown'),
                        initialValue: _roleToAdd,
                        decoration: const InputDecoration(labelText: 'Add role'),
                        items: [
                          for (final role in remainingRoles)
                            DropdownMenuItem(
                              value: role,
                              child: KeyedSubtree(
                                key: Key('edit_role_option_${role.wireValue}'),
                                child: Text(role.wireValue),
                              ),
                            ),
                        ],
                        onChanged: (value) => setState(() => _roleToAdd = value),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _savingRole
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : IconButton.filled(
                              key: const Key('edit_role_add_button'),
                              onPressed: _roleToAdd == null ? null : _addRole,
                              icon: const Icon(Icons.add),
                              tooltip: 'Add role',
                            ),
                    ),
                  ],
                ),
              ],
              if (_roleMessage != null) FormMessage(text: _roleMessage!, isError: _roleIsError),
              const Divider(height: 32),
              const Text('Account Status', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  StatusPill(
                    kind: _disabled
                        ? StatusPillKind.critical
                        : (_hasPassword ? StatusPillKind.active : StatusPillKind.warning),
                    label: _disabled ? 'Suspended' : (_hasPassword ? 'Active' : 'Invited'),
                  ),
                  StatusPill(
                    kind: _mfaEnrolled ? StatusPillKind.active : StatusPillKind.warning,
                    label: _mfaEnrolled ? 'Two-step sign-in on' : 'Two-step sign-in not set up',
                  ),
                ],
              ),
              if (_statusMessage != null) FormMessage(text: _statusMessage!, isError: _statusIsError),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!_hasPassword && !_disabled)
                    OutlinedButton.icon(
                      onPressed: _resendingInvite ? null : _resendInvite,
                      icon: _resendingInvite
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.mail_outline),
                      label: Text(_resendingInvite ? 'Sending…' : 'Resend Invite'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _togglingDisabled ? null : _toggleDisabled,
                    style: _disabled ? null : OutlinedButton.styleFrom(foregroundColor: AppColors.warning),
                    icon: _togglingDisabled
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _disabled ? null : AppColors.warning,
                            ),
                          )
                        : Icon(_disabled ? Icons.play_circle_outline : Icons.pause_circle_outline),
                    label: Text(_togglingDisabled ? 'Updating…' : (_disabled ? 'Reactivate' : 'Suspend')),
                  ),
                  // Available regardless of _mfaEnrolled — an admin might
                  // use this on a still-enrolled-but-locked-out user too,
                  // not just an obviously-unenrolled one.
                  OutlinedButton.icon(
                    onPressed: _resettingMfa ? null : _resetMfa,
                    icon: _resettingMfa
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.lock_reset),
                    label: Text(_resettingMfa ? 'Resetting…' : 'Reset Two-Step Sign-In'),
                  ),
                ],
              ),
              const Divider(height: 32),
              Text(
                'Danger Zone',
                style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
              if (_deleteError != null) FormMessage(text: _deleteError!, isError: true),
              OutlinedButton.icon(
                onPressed: _deleting ? null : _deleteAccount,
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                icon: _deleting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.danger),
                      )
                    : const Icon(Icons.delete_forever),
                label: Text(_deleting ? 'Deleting…' : 'Delete Account'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('edit_user_dialog_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.label, required this.removing, required this.onRemove});

  final String label;
  final bool removing;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: accent)),
          const SizedBox(width: 2),
          removing
              ? const Padding(
                  padding: EdgeInsets.all(4),
                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : InkWell(
                  onTap: onRemove,
                  customBorder: const CircleBorder(),
                  child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.close, size: 14)),
                ),
        ],
      ),
    );
  }
}
