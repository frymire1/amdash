import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_service.dart';
import '../auth/user_profile_service.dart';
import '../hospitals/hospital_service.dart';

/// Mirrors `libs/auth/src/lib/work-location/work-location.component.ts` —
/// a mandatory hospital picker for physician/nurse accounts before they can
/// reach the main app (see `AppRouteGuard`'s `requireWorkLocation`). The
/// autocomplete is only a suggestion list; the typed value must exactly
/// match a hospital from the live list to submit, same as the Angular
/// version's `hospitalNameValidator`.
class WorkLocationScreen extends ConsumerStatefulWidget {
  const WorkLocationScreen({super.key});

  @override
  ConsumerState<WorkLocationScreen> createState() => _WorkLocationScreenState();
}

class _WorkLocationScreenState extends ConsumerState<WorkLocationScreen> {
  String _typedValue = '';
  bool _touched = false;
  bool _submitting = false;
  String? _errorMessage;

  Future<void> _submit(List<String> hospitalNames) async {
    setState(() => _touched = true);
    if (!hospitalNames.contains(_typedValue)) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    final uid = ref.read(authServiceProvider).currentUser?.uid;
    if (uid == null) return;

    try {
      // Firestore never rejects a write blocked by a dropped connection —
      // it retries indefinitely instead — so this bounds how long the user
      // waits before seeing an error rather than a spinner stuck forever.
      // The underlying write isn't cancelled, and may still complete in the
      // background afterward.
      await ref.read(userProfileServiceProvider).saveWorkLocation(uid, _typedValue).timeout(
        const Duration(seconds: 15),
      );
      // Unlike the login screen, the guard chain has no rule that
      // proactively navigates *away* from `/work-location` once a
      // workLocation exists — it only blocks entry when one is missing.
      // Mirrors `work-location.component.ts`'s own explicit
      // `router.navigateByUrl('/')` after a successful save.
      if (mounted) context.go('/');
    } catch (error) {
      setState(() {
        _errorMessage = error.toString().contains('TimeoutException')
            ? 'This is taking longer than expected. Check your connection and try again.'
            : 'Failed to save your work location. Please try again.';
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hospitalNames = ref.watch(hospitalNamesProvider);
    final showError = _touched && !hospitalNames.contains(_typedValue);

    return Scaffold(
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
                        'Select Your Hospital',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Choose the hospital where you work, so we can show you nearby patients.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      Autocomplete<String>(
                        optionsBuilder: (textEditingValue) {
                          final query = textEditingValue.text.trim().toLowerCase();
                          if (query.isEmpty) return hospitalNames;
                          return hospitalNames.where((name) => name.toLowerCase().contains(query));
                        },
                        onSelected: (selection) => setState(() => _typedValue = selection),
                        fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
                          controller.addListener(() => _typedValue = controller.text);
                          return TextField(
                            controller: controller,
                            focusNode: focusNode,
                            decoration: InputDecoration(
                              labelText: 'Hospital',
                              errorText: showError ? 'Select a hospital from the list.' : null,
                            ),
                            onTapOutside: (_) => setState(() => _touched = true),
                          );
                        },
                      ),
                      if (_errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(color: Theme.of(context).colorScheme.error),
                          ),
                        ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _submitting ? null : () => _submit(hospitalNames),
                        child: _submitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
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
