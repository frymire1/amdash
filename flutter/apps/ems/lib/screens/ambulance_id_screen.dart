import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/ambulance_id_service.dart';

const _ambulanceIdMaxLength = 100;

/// A mandatory, one-time-per-device prompt for the physical vehicle's
/// Ambulance ID — structurally mirrors amdash_core's WorkLocationScreen
/// (touched/submitting/error-message state, a timeout-wrapped save,
/// `context.go('/')` on success), but simpler: a required free-text field
/// (trimmed, capped at [_ambulanceIdMaxLength] to match the server-side
/// limit in functions/src/ems.ts's publishAmbulanceLocation), no
/// autocomplete/validation against a live list. Only ever reachable when
/// AmbulanceIdGuard (router.dart) sends the app here — see that guard's
/// own doc comment for when that is.
class AmbulanceIdScreen extends ConsumerStatefulWidget {
  const AmbulanceIdScreen({super.key});

  @override
  ConsumerState<AmbulanceIdScreen> createState() => _AmbulanceIdScreenState();
}

class _AmbulanceIdScreenState extends ConsumerState<AmbulanceIdScreen> {
  final _controller = TextEditingController();
  bool _touched = false;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isValid {
    final trimmed = _controller.text.trim();
    return trimmed.isNotEmpty && trimmed.length <= _ambulanceIdMaxLength;
  }

  Future<void> _submit() async {
    setState(() => _touched = true);
    if (!_isValid) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      // Same bounded-wait reasoning as WorkLocationScreen's identical
      // timeout — a dropped connection never rejects a SharedPreferences
      // write outright, so this just bounds how long the user waits
      // before seeing an error rather than a spinner stuck forever.
      await ref.read(ambulanceIdServiceProvider).save(_controller.text.trim()).timeout(const Duration(seconds: 15));
      ref.invalidate(ambulanceIdProvider);
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
    final trimmedLength = _controller.text.trim().length;
    final showError = _touched && !_isValid;
    final errorText = !showError
        ? null
        : trimmedLength > _ambulanceIdMaxLength
        ? 'Must be $_ambulanceIdMaxLength characters or fewer.'
        : 'Enter the ambulance ID.';

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
                        controller: _controller,
                        decoration: InputDecoration(labelText: 'Ambulance ID', errorText: errorText),
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
