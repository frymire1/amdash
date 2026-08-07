import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Physician/nurse's own user-settings screen — name fields, the hospital
/// (work-location) field for changing an already-set location (the
/// mandatory first pick is `WorkLocationScreen`'s job), and new-patient
/// push-alert arming. Both apply unconditionally here, unlike the old
/// shared `amdash_core` version this was split off from, since this app is
/// only ever used by physician/nurse accounts. Profile and hospital are
/// separate cards with their own Save action, each with its own
/// loading/success/error state — this screen stays put after a save (no
/// auto-navigate-away) so the confirmation is actually visible, and so
/// saving one doesn't require re-touching the other.
class UserSettingsScreen extends ConsumerStatefulWidget {
  const UserSettingsScreen({super.key});

  @override
  ConsumerState<UserSettingsScreen> createState() => _UserSettingsScreenState();
}

class _UserSettingsScreenState extends ConsumerState<UserSettingsScreen> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  String _typedHospital = '';
  bool _hospitalTouched = false;

  int _selectedAlertHours = 4;
  bool _enablingAlerts = false;
  bool _disablingAlerts = false;
  String? _alertsBlockedMessage;

  bool _savingProfile = false;
  String? _profileError;
  String? _profileSuccess;

  bool _savingHospital = false;
  String? _hospitalError;
  String? _hospitalSuccess;

  bool _prefilled = false;

  Timer? _tickTimer;
  int _nowMs = DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    // Ticks every 60s (matching EmsLocationService's own recheck-interval
    // pattern) purely so the "alerts armed until…" line flips itself back
    // to "off" once the window elapses, with no reload needed.
    _tickTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() => _nowMs = DateTime.now().millisecondsSinceEpoch);
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  void _prefillIfNeeded(UserProfile profile) {
    if (_prefilled) return;
    _prefilled = true;
    _firstNameController.text = profile.firstName ?? '';
    _lastNameController.text = profile.lastName ?? '';
    _typedHospital = profile.workLocation ?? '';
  }

  Future<void> _enableAlerts(String uid) async {
    setState(() {
      _enablingAlerts = true;
      _alertsBlockedMessage = null;
    });
    try {
      final result = await ref.read(patientAlertServiceProvider).enableAlerts(uid, _selectedAlertHours);
      if (!result.granted) {
        setState(() {
          _alertsBlockedMessage =
              "Notifications are blocked in your browser — enable them in your browser's site settings for AmDash to receive alerts.";
        });
      }
    } catch (error) {
      setState(() => _alertsBlockedMessage = 'Failed to enable alerts. Please try again.');
    } finally {
      if (mounted) setState(() => _enablingAlerts = false);
    }
  }

  Future<void> _disableAlerts(String uid) async {
    setState(() => _disablingAlerts = true);
    try {
      await ref.read(patientAlertServiceProvider).disableAlerts(uid);
    } catch (_) {
      // Mirrors the Angular version: failures here are logged, not surfaced.
    } finally {
      if (mounted) setState(() => _disablingAlerts = false);
    }
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

  Future<void> _submitHospital(String uid, List<String> hospitalNames) async {
    setState(() => _hospitalTouched = true);
    final hospitalInvalid = _typedHospital.isEmpty || !hospitalNames.contains(_typedHospital);
    if (hospitalInvalid) return;

    setState(() {
      _savingHospital = true;
      _hospitalError = null;
      _hospitalSuccess = null;
    });
    try {
      await ref.read(userProfileServiceProvider).saveWorkLocation(uid, _typedHospital).timeout(
        const Duration(seconds: 15),
      );
      if (mounted) setState(() => _hospitalSuccess = 'Saved.');
    } catch (error) {
      if (mounted) {
        setState(() {
          _hospitalError = error.toString().contains('TimeoutException')
              ? 'This is taking longer than expected. Check your connection and try again.'
              : 'Failed to save your hospital. Please try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _savingHospital = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(userProfileProvider);
    final profile = profileAsync.valueOrNull;
    final uid = ref.watch(authStateProvider).valueOrNull?.uid;
    final hospitalNames = ref.watch(hospitalNamesProvider);

    if (profile != null) _prefillIfNeeded(profile);

    final hospitalInvalid =
        _hospitalTouched && _typedHospital.isNotEmpty && !hospitalNames.contains(_typedHospital);

    final expiresAt = profile?.newPatientAlertsExpiresAt;
    final alertsActive = expiresAt != null && expiresAt.millisecondsSinceEpoch > _nowMs;

    if (uid == null) return const SizedBox.shrink();

    // No AppBar of its own — this screen lives inside the app's
    // ShellRoute, which owns the real navbar.
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
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
                        'User Settings',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                      ),
                    ),
                    // Balances the leading IconButton's width so the title
                    // is actually centered, not just centered within the
                    // remaining space after it.
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
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('Hospital', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        Autocomplete<String>(
                          initialValue: TextEditingValue(text: _typedHospital),
                          optionsBuilder: (textEditingValue) {
                            final query = textEditingValue.text.trim().toLowerCase();
                            if (query.isEmpty) return hospitalNames;
                            return hospitalNames.where((name) => name.toLowerCase().contains(query));
                          },
                          onSelected: (selection) => setState(() => _typedHospital = selection),
                          fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
                            controller.addListener(() => _typedHospital = controller.text);
                            return TextField(
                              controller: controller,
                              focusNode: focusNode,
                              decoration: InputDecoration(
                                labelText: 'Hospital',
                                errorText: hospitalInvalid ? 'Select a hospital from the list.' : null,
                              ),
                              onTapOutside: (_) => setState(() => _hospitalTouched = true),
                            );
                          },
                        ),
                        _StatusLine(error: _hospitalError, success: _hospitalSuccess),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _savingHospital ? null : () => _submitHospital(uid, hospitalNames),
                          child: _savingHospital
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
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('New Patient Alerts', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        if (alertsActive)
                          Text(
                            'Alerts armed until ${expiresAt.toDate().toLocal()}',
                            style: const TextStyle(color: Colors.green),
                          )
                        else
                          const Text('Alerts are currently off.'),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Text('Duration:'),
                            const SizedBox(width: 12),
                            DropdownButton<int>(
                              value: _selectedAlertHours,
                              items: [
                                for (var h = 1; h <= 12; h++)
                                  DropdownMenuItem(value: h, child: Text('$h hour${h > 1 ? 's' : ''}')),
                              ],
                              onChanged: (value) {
                                if (value != null) setState(() => _selectedAlertHours = value);
                              },
                            ),
                          ],
                        ),
                        if (_alertsBlockedMessage != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _alertsBlockedMessage!,
                              style: TextStyle(color: Theme.of(context).colorScheme.error),
                            ),
                          ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            FilledButton(
                              onPressed: _enablingAlerts ? null : () => _enableAlerts(uid),
                              child: Text(_enablingAlerts ? 'Enabling…' : 'Enable'),
                            ),
                            const SizedBox(width: 12),
                            OutlinedButton(
                              onPressed: _disablingAlerts ? null : () => _disableAlerts(uid),
                              child: Text(_disablingAlerts ? 'Disabling…' : 'Disable'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
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
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 18),
            const SizedBox(width: 6),
            Text(success!, style: const TextStyle(color: Colors.green)),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
