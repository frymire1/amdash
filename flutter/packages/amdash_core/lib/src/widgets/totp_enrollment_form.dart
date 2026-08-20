import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../auth/auth_service.dart';
import '../auth/mfa_service.dart';
import 'dialogs.dart';

/// The "generate a TOTP secret, show it as a QR code + manual-entry
/// fallback, confirm a 6-digit code" enrollment sub-flow — shared by
/// `MfaSetupScreen` (mandatory, first-time enrollment) and
/// `MfaSecurityCard` (self-service device change), so there's exactly one
/// implementation of this security-critical logic rather than two
/// independently-maintained copies.
class TotpEnrollmentForm extends ConsumerStatefulWidget {
  const TotpEnrollmentForm({required this.onEnrolled, super.key});

  /// Called once `enroll()` actually succeeds (after this widget has
  /// already invalidated `mfaEnrolledFactorsProvider`) — the caller
  /// decides what "done" means: navigate away, close a dialog, collapse a
  /// card, etc.
  final VoidCallback onEnrolled;

  @override
  ConsumerState<TotpEnrollmentForm> createState() => _TotpEnrollmentFormState();
}

class _TotpEnrollmentFormState extends ConsumerState<TotpEnrollmentForm> {
  bool _starting = false;
  TotpSecret? _secret;
  String? _qrCodeUrl;
  final _codeController = TextEditingController();
  bool _confirming = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final secret = await ref
          .read(mfaServiceProvider)
          .beginEnrollment()
          .timeout(const Duration(seconds: 15));
      final email = ref.read(authServiceProvider).currentUser?.email ?? '';
      final qrCodeUrl = await secret.generateQrCodeUrl(
        accountName: email,
        issuer: 'AmDash',
      );
      if (mounted) {
        setState(() {
          _secret = secret;
          _qrCodeUrl = qrCodeUrl;
        });
      }
    } on MfaRequiresRecentLoginException {
      if (mounted) setState(() => _starting = false);
      await _reauthenticateThenRetry(_begin);
      return;
    } catch (error) {
      if (mounted)
        setState(
          () => _error = 'Could not start enrollment. Please try again.',
        );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _reauthenticateThenRetry(Future<void> Function() retry) async {
    final password = await showReauthPasswordDialog(context);
    if (password == null || !mounted) return;
    try {
      await ref.read(mfaServiceProvider).reauthenticate(password);
      await retry();
    } catch (error) {
      if (mounted)
        setState(
          () => _error = "Couldn't verify your password. Please try again.",
        );
    }
  }

  Future<void> _confirm() async {
    final secret = _secret;
    final code = _codeController.text.trim();
    if (secret == null || code.isEmpty) return;

    setState(() {
      _confirming = true;
      _error = null;
    });
    try {
      await ref
          .read(mfaServiceProvider)
          .confirmEnrollment(secret, code)
          .timeout(const Duration(seconds: 15));
      ref.invalidate(mfaEnrolledFactorsProvider);
      if (mounted) widget.onEnrolled();
    } on MfaRequiresRecentLoginException {
      if (mounted) setState(() => _confirming = false);
      await _reauthenticateThenRetry(_confirm);
      return;
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              "That code didn't work — double-check your authenticator app and try again.",
        );
      }
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final secret = _secret;
    final qrCodeUrl = _qrCodeUrl;

    if (secret == null || qrCodeUrl == null) {
      return Center(
        child: _starting
            ? _spinner(label: 'Preparing…')
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null) _messageText(context, _error!),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _begin,
                    child: const Text('Try again'),
                  ),
                ],
              ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: QrImageView(
            data: qrCodeUrl,
            size: 200,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          "Can't scan? Enter this code manually:",
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 4),
        SelectableText(
          secret.secretKey,
          key: const Key('mfa_secret_key'),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _codeController,
          decoration: const InputDecoration(labelText: '6-digit code'),
          keyboardType: TextInputType.number,
          maxLength: 6,
          onSubmitted: (_) => _confirm(),
        ),
        if (_error != null) _messageText(context, _error!),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _confirming ? null : _confirm,
          child: _confirming
              ? _spinner(label: 'Confirming…')
              : const Text('Confirm'),
        ),
        TextButton(
          onPressed: () => setState(() {
            _secret = null;
            _qrCodeUrl = null;
          }),
          child: const Text('Generate a new code'),
        ),
      ],
    );
  }

  Widget _spinner({String? label}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        if (label != null) ...[const SizedBox(width: 12), Text(label)],
      ],
    );
  }

  Widget _messageText(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}
