import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'login_screen.dart';
import 'signed_in_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const ProviderScope(child: EmsApp()));
}

class EmsApp extends StatelessWidget {
  const EmsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AmDash — EMS',
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      home: const _AuthGate(),
    );
  }
}

/// Phase 0 walking skeleton: swaps between the login screen and a
/// placeholder "signed in" screen based on Firebase Auth state — proves
/// real end-to-end auth against amdash-dev. The full go_router redirect
/// chain (auth -> role -> work-location, mirroring
/// `libs/auth/src/lib/guards/auth.guard.ts`) belongs in Phase 1, once
/// there's an actual home route and role check to guard.
class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);

    return authState.when(
      data: (user) =>
          user == null ? const LoginScreen() : const SignedInScreen(),
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => Scaffold(
        body: Center(child: Text('Something went wrong: $error')),
      ),
    );
  }
}
