import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/ambulance_id_service.dart';
import '../services/ambulance_phone_service.dart';

const _ambulanceIdMaxLength = 100;
const _ambulancePhoneMaxLength = 30;

/// A mandatory, one-time-per-device prompt for the physical vehicle's
/// Ambulance ID and the best phone number to reach its crew —
/// structurally mirrors amdash_core's WorkLocationScreen
/// (touched/submitting/error-message state, a timeout-wrapped save,
/// `context.go('/')` on success), but simpler: two required free-text
/// fields (trimmed, capped at [_ambulanceIdMaxLength]/
/// [_ambulancePhoneMaxLength] to match the server-side limits in
/// functions/src/ems.ts's publishAmbulanceLocation), no
/// autocomplete/validation against a live list or a phone-format regex.
/// One shared [_touched] flag gates both fields' errors — simpler than
/// independent per-field touch state, and this form has never needed to
/// generalize past that. Only ever reachable when AmbulanceIdGuard
/// (router.dart) sends the app here — see that guard's own doc comment
/// for when that is.
class AmbulanceIdScreen extends ConsumerStatefulWidget {
  const AmbulanceIdScreen({super.key});

  @override
  ConsumerState<AmbulanceIdScreen> createState() => _AmbulanceIdScreenState();
}

class _AmbulanceIdScreenState extends ConsumerState<AmbulanceIdScreen> {
  final _idController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _touched = false;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _idController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  bool get _isIdValid {
    final trimmed = _idController.text.trim();
    return trimmed.isNotEmpty && trimmed.length <= _ambulanceIdMaxLength;
  }

  bool get _isPhoneValid {
    final trimmed = _phoneController.text.trim();
    return trimmed.isNotEmpty && trimmed.length <= _ambulancePhoneMaxLength;
  }

  Future<void> _submit() async {
    setState(() => _touched = true);
    if (!_isIdValid || !_isPhoneValid) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      // Same bounded-wait reasoning as WorkLocationScreen's identical
      // timeout — a dropped connection never rejects a SharedPreferences
      // write outright, so this just bounds how long the user waits
      // before seeing an error rather than a spinner stuck forever. Both
      // saves race under the one timeout together, same as they'll both
      // be required together going forward — no need to distinguish which
      // one failed.
      await Future.wait([
        ref.read(ambulanceIdServiceProvider).save(_idController.text.trim()),
        ref.read(ambulancePhoneServiceProvider).save(_phoneController.text.trim()),
      ]).timeout(const Duration(seconds: 15));
      ref.invalidate(ambulanceIdProvider);
      ref.invalidate(ambulancePhoneProvider);
      if (mounted) context.go('/');
    } catch (error) {
      setState(() {
        _errorMessage = error.toString().contains('TimeoutException')
            ? 'This is taking longer than expected. Check your connection and try again.'
            : 'Failed to save. Please try again.';
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final idLength = _idController.text.trim().length;
    final showIdError = _touched && !_isIdValid;
    final idErrorText = !showIdError
        ? null
        : idLength > _ambulanceIdMaxLength
        ? 'Must be $_ambulanceIdMaxLength characters or fewer.'
        : 'Enter the ambulance ID.';

    final phoneLength = _phoneController.text.trim().length;
    final showPhoneError = _touched && !_isPhoneValid;
    final phoneErrorText = !showPhoneError
        ? null
        : phoneLength > _ambulancePhoneMaxLength
        ? 'Must be $_ambulancePhoneMaxLength characters or fewer.'
        : 'Enter a phone number.';

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'What ambulance are you in today?',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "This identifies your vehicle to receiving physicians on the fleet map. It's saved on "
                        "this device, so you won't be asked again here — only if you sign in on a different one.",
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        key: const Key('ambulance_id_field'),
                        controller: _idController,
                        decoration: InputDecoration(labelText: 'Ambulance ID', errorText: idErrorText),
                        onChanged: (_) => setState(() {}),
                        onTapOutside: (_) => setState(() => _touched = true),
                        onSubmitted: (_) => _submit(),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        key: const Key('ambulance_phone_field'),
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: 'Best phone number to reach this crew',
                          errorText: phoneErrorText,
                        ),
                        onChanged: (_) => setState(() {}),
                        onTapOutside: (_) => setState(() => _touched = true),
                        onSubmitted: (_) => _submit(),
                      ),
                      if (_errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(_errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                        ),
                      const SizedBox(height: 20),
                      FilledButton(
                        key: const Key('ambulance_id_submit'),
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Continue'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
