import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'router.dart';
import 'web/service_worker_registration.dart';

// See ems/lib/main.dart's identical constants for the rationale — same
// pattern, duplicated per-app since there's no shared Firebase bootstrap
// helper in amdash_core.
const _appCheckDebugToken = String.fromEnvironment('FIREBASE_APPCHECK_DEBUG_TOKEN');
const _appCheckRecaptchaSiteKey = String.fromEnvironment('APP_CHECK_RECAPTCHA_SITE_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Monitor mode only — see SECURITY.md.
  await FirebaseAppCheck.instance.activate(
    providerAndroid: kDebugMode
        ? AndroidDebugProvider(debugToken: _appCheckDebugToken.isEmpty ? null : _appCheckDebugToken)
        : const AndroidPlayIntegrityProvider(),
    providerApple: kDebugMode
        ? AppleDebugProvider(debugToken: _appCheckDebugToken.isEmpty ? null : _appCheckDebugToken)
        : const AppleAppAttestWithDeviceCheckFallbackProvider(),
    // Enterprise, not classic v3 — see admin/lib/main.dart's identical note.
    providerWeb: ReCaptchaEnterpriseProvider(_appCheckRecaptchaSiteKey),
  );

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
