import 'package:flutter/material.dart';

/// Mirrors `confirm-dialog.component.ts`'s generic Yes/No modal.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Yes',
  String cancelLabel = 'Cancel',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Mirrors `error-dialog.component.ts`'s generic dismissable error modal.
Future<void> showErrorDialog(
  BuildContext context, {
  required String title,
  required String message,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Prompts for the current password and returns it, or `null` if cancelled.
/// Firebase treats MFA enroll/unenroll as a "sensitive operation" that can
/// throw `requires-recent-login` once a session is a while old — the mfa
/// setup screen and the self-service re-enroll flow both call this to
/// obtain a fresh credential to reauthenticate with before retrying, rather
/// than each hand-rolling their own password prompt.
Future<String?> showReauthPasswordDialog(
  BuildContext context, {
  String title = 'Confirm your password',
  String message = 'For your security, please re-enter your password to continue.',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ReauthPasswordDialog(title: title, message: message),
  );
}

// A real StatefulWidget (not a closure-scoped TextEditingController manually
// disposed via showDialog's own .whenComplete, which this used to be) —
// confirmed for real via a widget test that the old shape disposed the
// controller the instant Navigator.pop() resolves the returned Future,
// which is *before* the dialog's own exit transition finishes animating
// (the route is merely "popped", not yet removed from the tree) — the
// still-animating TextField then throws "A TextEditingController was used
// after being disposed" on the very next frame. A State's own dispose()
// only runs once its element is actually removed from the tree, i.e. after
// the exit transition completes, which is what this needs.
class _ReauthPasswordDialog extends StatefulWidget {
  const _ReauthPasswordDialog({required this.title, required this.message});

  final String title;
  final String message;

  @override
  State<_ReauthPasswordDialog> createState() => _ReauthPasswordDialogState();
}

class _ReauthPasswordDialogState extends State<_ReauthPasswordDialog> {
  final _controller = TextEditingController();
  var _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (value) => value.isEmpty ? null : Navigator.of(context).pop(value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final value = _controller.text;
            if (value.isNotEmpty) Navigator.of(context).pop(value);
          },
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
