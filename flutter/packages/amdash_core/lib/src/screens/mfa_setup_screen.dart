import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_service.dart';
import '../widgets/totp_enrollment_form.dart';

/// Mandatory before reaching the main app for every account (see
/// `AppRouteGuard`'s `requireMfa` tier and admin's equivalent hand-added
/// check) — modeled directly on `work_location_screen.dart`'s shape: the
/// guard only ever *blocks* entry here, this screen owns the
/// `context.go('/')` exit once enrollment actually completes. Two
/// sub-steps: Firebase requires a verified email before it'll let a TOTP
/// factor be enrolled at all, and nothing in AmDash verifies email today,
/// so that has to happen first; the actual TOTP enrollment UI/logic is
/// shared with the self-service re-enroll flow via `TotpEnrollmentForm`.
class MfaSetupScreen extends ConsumerStatefulWidget {
  const MfaSetupScreen({super.key});

  @override
  ConsumerState<MfaSetupScreen> createState() => _MfaSetupScreenState();
}

class _MfaSetupScreenState extends ConsumerState<MfaSetupScreen> {
  bool _sendingVerification = false;
  bool _checkingVerification = false;
  String? _emailMessage;
  bool _emailMessageIsError = false;

  bool get _isEmailVerified => ref.read(authServiceProvider).currentUser?.emailVerified ?? false;

  Future<void> _sendVerificationEmail() async {
    setState(() {
      _sendingVerification = true;
      _emailMessage = null;
    });
    try {
      // Routed through the requestEmailVerification callable
      // (functions/src/shared.ts), not currentUser.sendEmailVerification()
      // — that method sends Firebase's own unbranded email with no way to
      // swap just the delivery. The callable mints the same kind of link
      // via the Admin SDK and sends a branded email through Resend
      // instead (see AuthService.sendEmailVerification's own comment).
      await ref.read(authServiceProvider).sendEmailVerification().timeout(const Duration(seconds: 15));
      if (mounted) {
        setState(() {
          _emailMessage = 'Verification email sent — check your inbox.';
          _emailMessageIsError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _emailMessage = 'Could not send a verification email. Please try again.';
          _emailMessageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _sendingVerification = false);
    }
  }

  Future<void> _checkVerified() async {
    setState(() {
      _checkingVerification = true;
      _emailMessage = null;
    });
    try {
      // emailVerified isn't pushed live — reload() is the only way to
      // learn the link was actually clicked.
      await ref.read(authServiceProvider).currentUser?.reload().timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (_isEmailVerified) {
        setState(() {});
      } else {
        setState(() {
          _emailMessage = 'Still not verified — check your inbox (and spam folder) for the link.';
          _emailMessageIsError = true;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _emailMessage = 'Could not check verification status. Please try again.';
          _emailMessageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _checkingVerification = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _isEmailVerified ? _buildEnrollStep(context) : _buildVerifyEmailStep(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildVerifyEmailStep(BuildContext context) {
    final email = ref.read(authServiceProvider).currentUser?.email ?? '';
    return [
      const Text('Verify your email', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text(
        'Every AmDash account now requires a second sign-in step. Before setting that up, we need to confirm '
        '$email is really yours — check your inbox for a verification link.',
      ),
      const SizedBox(height: 20),
      if (_emailMessage != null) _messageText(context, _emailMessage!, isError: _emailMessageIsError),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: _sendingVerification ? null : _sendVerificationEmail,
        child: _sendingVerification ? _spinner() : const Text('Resend verification email'),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _checkingVerification ? null : _checkVerified,
        child: _checkingVerification ? _spinner(label: 'Checking…') : const Text("I've verified — continue"),
      ),
    ];
  }

  List<Widget> _buildEnrollStep(BuildContext context) {
    return [
      const Text('Set up your authenticator app', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      const Text(
        'Scan this code with an authenticator app (Google Authenticator, Authy, 1Password, etc.), then enter '
        'the 6-digit code it shows you.',
      ),
      const SizedBox(height: 20),
      // ref.invalidate(mfaEnrolledFactorsProvider) already happened inside
      // TotpEnrollmentForm by the time onEnrolled fires — this only needs
      // to own the "where do we go once it's done" half.
      TotpEnrollmentForm(onEnrolled: () => context.go('/')),
    ];
  }

  Widget _spinner({String? label}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        if (label != null) ...[const SizedBox(width: 12), Text(label)],
      ],
    );
  }

  Widget _messageText(BuildContext context, String text, {required bool isError}) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: TextStyle(color: isError ? Theme.of(context).colorScheme.error : null),
      ),
    );
  }
}
