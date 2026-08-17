import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/mfa_service.dart';
import 'dialogs.dart';
import 'totp_enrollment_form.dart';

/// A "Security" card for each app's user-settings screen — voluntary
/// device changes (lost phone, new phone) without needing an admin.
/// Dropped verbatim into all three apps' `user_settings_screen.dart`
/// rather than copy-pasted, unlike this codebase's usual per-app-private
/// convention for purely cosmetic settings cards: unenroll/re-enroll is
/// security-critical enough that three independently-maintained copies
/// would be a real drift risk.
///
/// Self-service can never fix a real lockout (a user who's lost their
/// device can't sign in at all, so never reaches this screen) — that's
/// what the admin-triggered `resetUserMfa` callable is for. This card is
/// only reachable by someone who's already signed in and wants to
/// deliberately swap authenticators.
class MfaSecurityCard extends ConsumerStatefulWidget {
  const MfaSecurityCard({super.key});

  @override
  ConsumerState<MfaSecurityCard> createState() => _MfaSecurityCardState();
}

class _MfaSecurityCardState extends ConsumerState<MfaSecurityCard> {
  bool _changing = false;
  bool _unenrolling = false;
  String? _error;

  Future<void> _startChange() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Change authenticator app?',
      message:
          "This removes your current authenticator and immediately walks you through setting up a new one — "
          "don't start this unless you're ready to finish it in one sitting.",
      confirmLabel: 'Continue',
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _unenrolling = true;
      _error = null;
    });
    try {
      // Always unenroll before starting the new enrollment, never after —
      // enroll() adds to the factor list rather than replacing, and
      // leaving two enrolled factors risks a later sign-in challenge
      // resolving against the dead one. Safe if abandoned mid-way: zero
      // factors just routes back through mandatory /mfa-setup next time.
      await ref.read(mfaServiceProvider).unenrollTotp().timeout(const Duration(seconds: 15));
      ref.invalidate(mfaEnrolledFactorsProvider);
      if (mounted) setState(() => _changing = true);
    } on MfaRequiresRecentLoginException {
      if (!mounted) return;
      final password = await showReauthPasswordDialog(context);
      if (password == null || !mounted) return;
      try {
        await ref.read(mfaServiceProvider).reauthenticate(password);
        await _startChange();
        return;
      } catch (error) {
        if (mounted) setState(() => _error = "Couldn't verify your password. Please try again.");
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not remove your current authenticator. Please try again.');
    } finally {
      if (mounted) setState(() => _unenrolling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enrolledFactors = ref.watch(mfaEnrolledFactorsProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Security', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_changing) ...[
              const Text('Scan the new code, then confirm it below.'),
              const SizedBox(height: 16),
              TotpEnrollmentForm(onEnrolled: () => setState(() => _changing = false)),
            ] else ...[
              enrolledFactors.when(
                data: (factors) => Text(
                  factors.isNotEmpty
                      ? 'Two-step sign-in is on, using an authenticator app.'
                      : "Two-step sign-in isn't set up yet.",
                ),
                loading: () => const Text('Checking your two-step sign-in status…'),
                error: (_, _) => const Text("Couldn't load your two-step sign-in status."),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _unenrolling ? null : _startChange,
                child: _unenrolling
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Change authenticator app'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
