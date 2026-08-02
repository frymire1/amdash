import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'router.dart';
import 'web/service_worker_registration.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Required for background push delivery on web (and PWA installability —
  // Chrome requires a controlling service worker with a fetch handler
  // before offering "Install AmDash"). No-op on non-web platforms.
  registerFirebaseMessagingServiceWorker();
  runApp(const ProviderScope(child: PhysicianApp()));
}

class PhysicianApp extends ConsumerWidget {
  const PhysicianApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'AmDash — Physician',
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      routerConfig: router,
    );
  }
}
