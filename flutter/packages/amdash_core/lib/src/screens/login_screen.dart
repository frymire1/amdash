import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_service.dart';

/// Mirrors `libs/auth/src/lib/login/login.component.ts`'s email-first flow:
/// submitting an email decides server-side (via `checkAccountStatus`)
/// whether this lands on "not activated" (no account — AmDash has no
/// self-registration), "set a password" (an admin-created account with no
/// password yet), or a normal password sign-in.
enum _LoginStep { email, notActivated, setPassword, signIn }

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

  _LoginStep _step = _LoginStep.email;
  bool _submitting = false;
  bool _resetSubmitting = false;
  String? _errorMessage;
  String? _resetMessage;

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
    } on FirebaseAuthException {
      setState(() => _errorMessage = 'Invalid email or password.');
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
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
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
            decoration: const InputDecoration(labelText: 'Confirm Password'),
            obscureText: true,
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
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
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
      child: Text(text, style: const TextStyle(color: Colors.green)),
    );
  }
}
