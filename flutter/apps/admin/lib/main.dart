import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'router.dart';

// See ems/lib/main.dart's identical constant for the rationale. No
// Android/Apple debug-token wiring here — admin has no android/ios
// directory at all (web-only), so there's no debug provider for one to
// apply to.
const _appCheckRecaptchaSiteKey = String.fromEnvironment('APP_CHECK_RECAPTCHA_SITE_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Monitor mode only — see SECURITY.md. Enterprise, not classic v3 — the
  // key registered in the App Check console is a reCAPTCHA Enterprise key
  // (console defaults to Enterprise now; there's no separate v3 option in
  // the current registration flow), and the two aren't interchangeable —
  // ReCaptchaV3Provider expects a classic v3 site key and won't validate
  // against an Enterprise key ID.
  await FirebaseAppCheck.instance.activate(providerWeb: ReCaptchaEnterpriseProvider(_appCheckRecaptchaSiteKey));

  runApp(const ProviderScope(child: AdminApp()));
}

class AdminApp extends ConsumerWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'AmDash — Admin',
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      builder: (context, child) => IdleTimeoutWrapper(child: child ?? const SizedBox.shrink()),
    );
  }
}
