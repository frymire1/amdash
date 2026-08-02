import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Placeholder for the Phase 0 walking skeleton — proves a real signed-in
/// session and a real Firestore profile read both work. Replaced by the
/// real home screen + nav bar in Phase 1.
class SignedInScreen extends ConsumerWidget {
  const SignedInScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileState = ref.watch(userProfileProvider);
    final authService = ref.watch(authServiceProvider);
    final user = authService.currentUser;

    return Scaffold(
      appBar: AppBar(title: const Text('AmDash — EMS')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Signed in as ${user?.email}'),
            const SizedBox(height: 8),
            profileState.when(
              data: (profile) => Text(
                profile == null
                    ? 'No profile document yet.'
                    : 'Profile loaded — role: ${profile.role.map((r) => r.wireValue).join(', ')}',
              ),
              loading: () => const CircularProgressIndicator(),
              error: (error, stackTrace) => Text('Failed to load profile: $error'),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => authService.signOut(),
              child: const Text('Log out'),
            ),
          ],
        ),
      ),
    );
  }
}
