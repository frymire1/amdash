import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Mirrors `libs/auth/src/lib/login/login.component.ts`'s email-first flow:
/// submitting an email decides server-side (via `checkAccountStatus`)
/// whether this lands on "not activated" (no account — AmDash has no
/// self-registration), "set a password" (an admin-created account with no
/// password yet), or a normal password sign-in.
enum _LoginStep { email, notActivated, setPassword, signIn }

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  _LoginStep _step = _LoginStep.email;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

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
        } else if (!status.hasPassword) {
          _step = _LoginStep.setPassword;
        } else {
          _step = _LoginStep.signIn;
        }
      });
    } catch (error) {
      setState(() => _errorMessage = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitSetPassword() async {
    final password = _passwordController.text;
    if (password.length < 6) {
      setState(() => _errorMessage = 'Password must be at least 6 characters.');
      return;
    }
    if (password != _confirmPasswordController.text) {
      setState(() => _errorMessage = 'Passwords do not match.');
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      await ref
          .read(authServiceProvider)
          .claimPasswordlessAccount(_emailController.text.trim(), password);
      // On success, authStateProvider picks up the new session and
      // _AuthGate swaps to SignedInScreen — nothing further to do here.
    } catch (error) {
      setState(() => _errorMessage = 'Failed to set your password. Please try again.');
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
      await ref
          .read(authServiceProvider)
          .signIn(_emailController.text.trim(), _passwordController.text);
    } on FirebaseAuthException {
      setState(() => _errorMessage = 'Invalid email or password.');
    } catch (error) {
      setState(() => _errorMessage = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _useDifferentEmail() {
    setState(() {
      _step = _LoginStep.email;
      _errorMessage = null;
      _passwordController.clear();
      _confirmPasswordController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
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
                    const Text(
                      'AmDash — EMS',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 24),
                    // Keyed on the step so Flutter fully disposes and
                    // recreates these fields across a step transition
                    // instead of reconciling same-shaped TextFields across
                    // semantically different steps (email step's field vs.
                    // sign-in step's field occupy the same tree position,
                    // and without a key Flutter reuses the element and its
                    // stale controller/focus/IME state rather than
                    // treating it as a new field).
                    KeyedSubtree(
                      key: ValueKey(_step),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _buildStepFields(),
                      ),
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildStepFields() {
    switch (_step) {
      case _LoginStep.email:
        return [
          TextField(
            controller: _emailController,
            decoration: const InputDecoration(labelText: 'Email'),
            keyboardType: TextInputType.emailAddress,
            onSubmitted: (_) => _submitEmail(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting ? null : _submitEmail,
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Continue'),
          ),
        ];
      case _LoginStep.notActivated:
        return [
          Text('Your email, ${_emailController.text.trim()}, has not been activated by your admin.'),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _useDifferentEmail,
            child: const Text('Use a different email'),
          ),
        ];
      case _LoginStep.setPassword:
        return [
          TextField(
            controller: _passwordController,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmPasswordController,
            decoration: const InputDecoration(labelText: 'Confirm Password'),
            obscureText: true,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting ? null : _submitSetPassword,
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Set Password'),
          ),
        ];
      case _LoginStep.signIn:
        return [
          TextField(
            controller: _passwordController,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
            onSubmitted: (_) => _submitSignIn(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting ? null : _submitSignIn,
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Sign In'),
          ),
        ];
    }
  }
}
