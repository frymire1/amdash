import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'router.dart';
import 'web/service_worker_registration.dart';

Future<void> main() async {
  // TODO(debug): temporary — tracking down a real, reported "patient list
  // spinner never stops on first load" bug, seen with only an opaque,
  // minified "Uncaught Error" in the browser console and no readable Dart
  // message. These log the actual exception + stack (still symbolized at
  // the Dart level even in a release web build, unlike the raw JS trace
  // Chrome shows on its own) for whichever zone catches it first. Remove
  // once the root cause is confirmed. See authStateProvider/
  // userProfileProvider/_rawPhysicianPatientsProvider's own TODO(debug)s
  // for the rest of this investigation's instrumentation.
  FlutterError.onError = (details) {
    debugPrint('[DIAG] FlutterError.onError: ${details.exceptionAsString()}\n${details.stack}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[DIAG] PlatformDispatcher.onError: $error\n$stack');
    return false; // Still let the platform's own default handling run too.
  };

  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      // Required for background push delivery on web (and PWA installability
      // — Chrome requires a controlling service worker with a fetch handler
      // before offering "Install AmDash"). No-op on non-web platforms.
      registerFirebaseMessagingServiceWorker();
      runApp(const ProviderScope(child: PhysicianApp()));
    },
    (error, stack) => debugPrint('[DIAG] runZonedGuarded caught: $error\n$stack'),
  );
}

class PhysicianApp extends ConsumerWidget {
  const PhysicianApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'AmDash — Physician',
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      builder: (context, child) => IdleTimeoutWrapper(child: child ?? const SizedBox.shrink()),
    );
  }
}
