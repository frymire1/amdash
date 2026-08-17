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
  final controller = TextEditingController();
  var obscure = true;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: obscure,
              decoration: InputDecoration(
                labelText: 'Password',
                suffixIcon: IconButton(
                  icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => obscure = !obscure),
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
              final value = controller.text;
              if (value.isNotEmpty) Navigator.of(context).pop(value);
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    ),
  ).whenComplete(controller.dispose);
}
