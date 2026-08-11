import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// EMS's own user-settings screen — name fields only. EMS has no
/// hospital/work-location field (that's a physician/nurse concern) and no
/// new-patient alerts (EMS uploads patients, it doesn't receive them) —
/// split off from a single shared screen that showed those sections based
/// on the *account's* roles rather than which app was running, which
/// leaked physician-only UI into EMS for any multi-role account.
class UserSettingsScreen extends ConsumerStatefulWidget {
  const UserSettingsScreen({super.key});

  @override
  ConsumerState<UserSettingsScreen> createState() => _UserSettingsScreenState();
}

class _UserSettingsScreenState extends ConsumerState<UserSettingsScreen> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();

  bool _prefilled = false;
  bool _savingProfile = false;
  String? _profileError;
  String? _profileSuccess;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  void _prefillIfNeeded(UserProfile profile) {
    if (_prefilled) return;
    _prefilled = true;
    _firstNameController.text = profile.firstName ?? '';
    _lastNameController.text = profile.lastName ?? '';
  }

  Future<void> _submitProfile(String uid) async {
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    if (firstName.isEmpty || lastName.isEmpty) return;

    setState(() {
      _savingProfile = true;
      _profileError = null;
      _profileSuccess = null;
    });
    try {
      await ref.read(userProfileServiceProvider).saveProfile(uid, firstName, lastName).timeout(
        const Duration(seconds: 15),
      );
      if (mounted) setState(() => _profileSuccess = 'Saved.');
    } catch (error) {
      if (mounted) {
        setState(() {
          _profileError = error.toString().contains('TimeoutException')
              ? 'This is taking longer than expected. Check your connection and try again.'
              : 'Failed to save your details. Please try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _savingProfile = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final uid = ref.watch(authStateProvider).valueOrNull?.uid;

    if (profile != null) _prefillIfNeeded(profile);
    if (uid == null) return const SizedBox.shrink();

    // No AppBar of its own — this screen lives inside the app's
    // ShellRoute, which owns the real navbar.
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    // NavBar (the shared shell appBar this screen lives
                    // under) is a fixed, uniform top nav with no back
                    // button by design, so this screen provides its own
                    // way back.
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Back',
                      onPressed: () => context.canPop() ? context.pop() : context.go('/'),
                    ),
                    const Expanded(
                      child: Text(
                        'User Info',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('Profile', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _firstNameController,
                          decoration: const InputDecoration(labelText: 'First Name'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _lastNameController,
                          decoration: const InputDecoration(labelText: 'Last Name'),
                        ),
                        _StatusLine(error: _profileError, success: _profileSuccess),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _savingProfile ? null : () => _submitProfile(uid),
                          child: _savingProfile
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Save'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const _AppearanceCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({this.error, this.success});

  final String? error;
  final String? success;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    if (success != null) {
      final successColor = context.palette.success;
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, color: successColor, size: 18),
            const SizedBox(width: 6),
            Text(success!, style: TextStyle(color: successColor)),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// Light/dark/system appearance control, wired to the shared
/// `themeModeProvider` (persisted via SharedPreferences) — defaults to
/// following the OS setting until explicitly changed here.
class _AppearanceCard extends ConsumerWidget {
  const _AppearanceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Appearance', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
                ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
              ],
              selected: {mode},
              onSelectionChanged: (selection) => ref.read(themeModeProvider.notifier).setMode(selection.first),
            ),
          ],
        ),
      ),
    );
  }
}
