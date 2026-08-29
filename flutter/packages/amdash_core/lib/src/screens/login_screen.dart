import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_service.dart';
import '../theme/app_theme.dart';

/// Mirrors `libs/auth/src/lib/login/login.component.ts`'s email-first flow:
/// submitting an email decides server-side (via `checkAccountStatus`)
/// whether this lands on "not activated" (no account — AmDash has no
/// self-registration), "set a password" (an admin-created account with no
/// password yet), or a normal password sign-in. `mfaChallenge` is newer
/// than the Angular source this mirrors — reached only from `signIn` when
/// Firebase itself throws `FirebaseAuthMultiFactorException` for an
/// already-enrolled account (a brand-new account reaching `setPassword`
/// can never have an enrolled factor yet, so that step never sees this).
enum _LoginStep { email, notActivated, setPassword, signIn, mfaChallenge }

/// Shared across every app (mirrors `libs/auth`'s NX-shared `LoginComponent`)
/// — [appName] is the only per-app customization (e.g. `'AmDash — EMS'`).
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({required this.appName, super.key});

  final String appName;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _mfaCodeController = TextEditingController();

  _LoginStep _step = _LoginStep.email;
  bool _submitting = false;
  bool _resetSubmitting = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  String? _errorMessage;
  String? _resetMessage;

  // Set only when Firebase throws FirebaseAuthMultiFactorException from
  // _submitSignIn — carries the in-flight challenge until resolved.
  MultiFactorResolver? _mfaResolver;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(() => setState(() {}));
    _confirmPasswordController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _mfaCodeController.dispose();
    super.dispose();
  }

  bool get _hasMinLength => _passwordController.text.length >= 8;
  bool get _hasUppercase => RegExp('[A-Z]').hasMatch(_passwordController.text);
  bool get _hasNumber => RegExp('[0-9]').hasMatch(_passwordController.text);
  bool get _hasSpecialChar => RegExp('[^A-Za-z0-9]').hasMatch(_passwordController.text);
  bool get _meetsPasswordStrength => _hasMinLength && _hasUppercase && _hasNumber && _hasSpecialChar;
  bool get _passwordsMatch =>
      _confirmPasswordController.text.isNotEmpty && _passwordController.text == _confirmPasswordController.text;
  bool get _allRequirementsMet => _meetsPasswordStrength && _passwordsMatch;

  Future<void> _submitEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final status = await ref.read(authServiceProvider).checkAccountStatus(email);
      setState(() {
        if (!status.exists) {
          _step = _LoginStep.notActivated;
        } else if (status.hasPassword) {
          _step = _LoginStep.signIn;
        } else {
          _step = _LoginStep.setPassword;
        }
      });
    } catch (error) {
      setState(() => _errorMessage = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitSetPassword() async {
    if (!_allRequirementsMet) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      await ref
          .read(authServiceProvider)
          .claimPasswordlessAccount(_emailController.text.trim(), _passwordController.text);
      // On success, authStateProvider picks up the new session and the
      // app's router redirect takes over — nothing further to do here.
    } catch (error) {
      setState(() => _errorMessage = 'Could not set your password. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitSignIn() async {
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      await ref.read(authServiceProvider).signIn(_emailController.text.trim(), _passwordController.text);
      // On success, authStateProvider picks up the new session and the
      // app's router redirect takes over — nothing further to do here.
    } on FirebaseAuthMultiFactorException catch (e) {
      // Must come before the bare `on FirebaseAuthException` clause below
      // — this extends it, and Dart matches catch clauses in source order,
      // so the reverse order would silently misreport every real MFA
      // challenge as "Invalid email or password" instead of prompting for
      // the code. Firebase throws this mid-sign-in for an
      // already-enrolled account; the session isn't fully established
      // until resolveSignIn() below succeeds.
      setState(() => _mfaResolver = e.resolver);
      setState(() => _step = _LoginStep.mfaChallenge);
    } on FirebaseAuthException {
      setState(() => _errorMessage = 'Invalid email or password.');
    } catch (error) {
      setState(() => _errorMessage = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitMfaChallenge() async {
    final resolver = _mfaResolver;
    final code = _mfaCodeController.text.trim();
    if (resolver == null || code.isEmpty) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final hint = resolver.hints.firstWhere((h) => h.factorId == 'totp');
      // coverage:ignore-start
      // Real platform-channel calls — confirmed for real (via a widget
      // test that pumped well past this await and found _submitting still
      // stuck true) that TotpMultiFactorGenerator.getAssertionForSignIn
      // never resolves at all in a plain Dart VM test (no platform
      // bindings for any real target) — unlike mfa_service.dart's
      // generateSecret/getAssertionForEnrollment, which at least throw
      // immediately, this one just hangs forever, so there's no way to
      // reach anything past this line, including the success path below.
      // Same category as mfa_service.dart's own two exclusions and
      // fhir_export_service.dart's FileSaver call — no DI seam fixes this.
      final assertion = await TotpMultiFactorGenerator.getAssertionForSignIn(hint.uid, code);
      await resolver.resolveSignIn(assertion);
      // Same pattern as every other success path in this file — let the
      // router's redirect react to authStateProvider rather than
      // navigating explicitly.
    } on FirebaseAuthException {
      // Reachable only from a real getAssertionForSignIn/resolveSignIn
      // failure above — since those never throw at all in a plain Dart VM
      // test (confirmed via bisection: they just hang forever), this
      // catch clause can't be reached here either. Kept as real
      // production error handling for a genuine Firebase-thrown invalid-
      // code response, not dead code — the generic catch/finally below
      // *are* reachable, though (via firstWhere's own StateError when no
      // totp hint matches), so only this specific clause is excluded.
      setState(() => _errorMessage = "That code didn't work. Please try again.");
      // coverage:ignore-end
    } catch (error) {
      setState(() => _errorMessage = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _forgotPassword() async {
    setState(() {
      _resetSubmitting = true;
      _errorMessage = null;
      _resetMessage = null;
    });

    try {
      await ref.read(authServiceProvider).resetPassword(_emailController.text.trim());
      setState(() => _resetMessage = 'Password reset email sent — check your inbox.');
    } catch (error) {
      setState(() => _errorMessage = 'Could not send a reset email for that address.');
    } finally {
      if (mounted) setState(() => _resetSubmitting = false);
    }
  }

  void _useDifferentEmail() {
    setState(() {
      _step = _LoginStep.email;
      _errorMessage = null;
      _resetMessage = null;
      _passwordController.clear();
      _confirmPasswordController.clear();
      _mfaCodeController.clear();
      _mfaResolver = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Every app's router has '/login' as its initialLocation, and
    // AppRouteGuard's redirect only ever re-runs once authStateProvider
    // actually resolves (see its own `if (authState.isLoading) return
    // null;`) — so without a guard here, an already-signed-in user
    // reloading the app sees this screen's real form flash on screen for
    // the brief window Firebase Auth needs to restore the persisted
    // session (notably async on web, which needs an IndexedDB lookup
    // before its first authStateChanges() emission) before getting
    // redirected past it.
    //
    // Checking isLoading alone isn't quite enough, though: the moment
    // authStateProvider actually resolves with a signed-in user, this
    // widget's own `ref.watch` and RouterRefreshNotifier's `ref.listen`
    // both react to the exact same state change, and there's no guarantee
    // the router finishes its redirect-away-from-/login before this
    // widget's next rebuild runs — if this widget wins that race, isLoading
    // is already false and the form would flash for a frame anyway (this
    // is the flash reappearing after MFA landed, not a new bug — MFA just
    // added enough extra work on the redirect side to make the router
    // reliably lose the race more often). A signed-in user should never be
    // looking at this form regardless of who wins that race, so gate on
    // "authenticated at all", not just "still loading" — the router is
    // always about to navigate away momentarily in that case anyway.
    final authState = ref.watch(authStateProvider);
    if (authState.isLoading || authState.valueOrNull != null) {
      return const Scaffold(backgroundColor: Colors.transparent, body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        widget.appName,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 24),
                      // Keyed on the step so Flutter fully disposes and
                      // recreates these fields across a step transition
                      // instead of reconciling same-shaped TextFields across
                      // semantically different steps.
                      KeyedSubtree(
                        key: ValueKey(_step),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _buildStepFields(context),
                        ),
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

  List<Widget> _buildStepFields(BuildContext context) {
    switch (_step) {
      case _LoginStep.email:
        return [
          const Text('Sign in to continue'),
          const SizedBox(height: 16),
          TextField(
            controller: _emailController,
            decoration: const InputDecoration(labelText: 'Email'),
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            onSubmitted: (_) => _submitEmail(),
          ),
          if (_errorMessage != null) _errorText(context, _errorMessage!),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting ? null : _submitEmail,
            child: _submitting ? _spinner() : const Text('Continue'),
          ),
        ];
      case _LoginStep.notActivated:
        return [
          const Text('Account not activated'),
          const SizedBox(height: 12),
          _errorText(
            context,
            'Your email, ${_emailController.text.trim()}, has not been activated by your admin. '
            'Contact your admin for further help.',
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _useDifferentEmail,
            child: const Text('Use a different email'),
          ),
        ];
      case _LoginStep.setPassword:
        final showHints = !_meetsPasswordStrength && _passwordController.text.isNotEmpty;
        return [
          const Text("Your admin team has set up your account, now just create a password."),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            obscureText: _obscurePassword,
            autofillHints: const [AutofillHints.newPassword],
          ),
          if (showHints)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_hasMinLength) const Text('•  At least 8 characters'),
                  if (!_hasUppercase) const Text('•  One uppercase letter'),
                  if (!_hasNumber) const Text('•  One number'),
                  if (!_hasSpecialChar) const Text('•  One special character'),
                ],
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmPasswordController,
            decoration: InputDecoration(
              labelText: 'Confirm Password',
              suffixIcon: IconButton(
                icon: Icon(_obscureConfirmPassword ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
              ),
            ),
            obscureText: _obscureConfirmPassword,
            autofillHints: const [AutofillHints.newPassword],
            onSubmitted: (_) => _submitSetPassword(),
          ),
          if (_confirmPasswordController.text.isNotEmpty)
            _passwordsMatch
                ? _successText(context, 'Passwords match!')
                : _errorText(context, 'Passwords do not match'),
          if (_errorMessage != null) _errorText(context, _errorMessage!),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting || !_allRequirementsMet ? null : _submitSetPassword,
            child: _submitting ? _spinner(label: 'Setting password…') : const Text('Set Password'),
          ),
          const SizedBox(height: 4),
          TextButton(onPressed: _useDifferentEmail, child: const Text('Use a different email')),
        ];
      case _LoginStep.signIn:
        return [
          Text('Sign in as ${_emailController.text.trim()}'),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            obscureText: _obscurePassword,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _submitSignIn(),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _resetSubmitting ? null : _forgotPassword,
              child: Text(_resetSubmitting ? 'Sending…' : 'Forgot password?'),
            ),
          ),
          if (_errorMessage != null) _errorText(context, _errorMessage!),
          if (_resetMessage != null) _successText(context, _resetMessage!),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _submitting ? null : _submitSignIn,
            child: _submitting ? _spinner(label: 'Signing in…') : const Text('Sign In'),
          ),
          const SizedBox(height: 4),
          TextButton(onPressed: _useDifferentEmail, child: const Text('Use a different email')),
        ];
      case _LoginStep.mfaChallenge:
        return [
          const Text('Enter the 6-digit code from your authenticator app'),
          const SizedBox(height: 16),
          TextField(
            controller: _mfaCodeController,
            decoration: const InputDecoration(labelText: '6-digit code'),
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofocus: true,
            onSubmitted: (_) => _submitMfaChallenge(),
          ),
          if (_errorMessage != null) _errorText(context, _errorMessage!),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _submitting ? null : _submitMfaChallenge,
            child: _submitting ? _spinner(label: 'Verifying…') : const Text('Verify'),
          ),
          const SizedBox(height: 4),
          TextButton(onPressed: _useDifferentEmail, child: const Text('Use a different email')),
        ];
    }
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

  Widget _errorText(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    );
  }

  Widget _successText(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(text, style: TextStyle(color: context.palette.success)),
    );
  }
}
