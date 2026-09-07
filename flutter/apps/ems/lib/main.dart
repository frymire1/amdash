import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'router.dart';
import 'web/service_worker_registration.dart';

// Empty string (the default when no --dart-define is passed) means "let the
// SDK auto-generate/print a debug token on first run" — only CI's Patrol
// jobs pass a real value, registered ahead of time in the Firebase Console
// under App Check → Manage debug tokens. See SECURITY.md.
const _appCheckDebugToken = String.fromEnvironment('FIREBASE_APPCHECK_DEBUG_TOKEN');

// Public by design (reCAPTCHA site keys are meant to be embedded in client
// code) — registered per-app in the Firebase Console's App Check tab. Empty
// default just means the web build's App Check activation is a no-op until
// that registration happens; nothing else here depends on it.
const _appCheckRecaptchaSiteKey = String.fromEnvironment('APP_CHECK_RECAPTCHA_SITE_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Attests requests genuinely come from this app instance — see
  // SECURITY.md. Registered in monitor mode only: tokens attach and are
  // logged, nothing is rejected yet (enforcement is a separate, later step).
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

  // iOS/macOS default to *not* displaying a push at all while the app is
  // in the foreground — it's silently delivered to the app process with
  // no banner/sound/badge unless explicitly opted into, which nothing
  // here otherwise does (no onMessage/foreground handler exists). Without
  // this, a connectivity-loss alert triggered by something the paramedic
  // just did in-app (e.g. toggling tracking off and saving) would arrive
  // successfully — confirmed for real via Cloud Functions' own logs
  // showing a clean send — yet never visibly appear, because the one
  // moment it's guaranteed to be sent is also the one moment the app is
  // guaranteed to be in the foreground. No-op on Android/web (a
  // foreground push already shows there by default; this call only
  // matches iOS/macOS's own opt-in requirement).
  await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );

  // Required before any FlutterForegroundTask.startService/sendDataToTask
  // calls — sets up the port the background isolate (see
  // services/ems_tracking_task_handler.dart) uses to talk back to this one.
  // flutter_foreground_task has no web implementation at all (see
  // ems_tracking_service.dart's header comment) — calling this
  // unconditionally crashes app boot on web.
  if (!kIsWeb) {
    FlutterForegroundTask.initCommunicationPort();
  }

  // Required for background push delivery on web (and PWA installability —
  // Chrome requires a controlling service worker with a fetch handler
  // before offering "Install AmDash"). No-op on non-web platforms. See
  // ems_alert_service.dart for what actually registers a token with it.
  registerFirebaseMessagingServiceWorker();

  runApp(const ProviderScope(child: EmsApp()));
}

class EmsApp extends ConsumerWidget {
  const EmsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'AmDash — EMS',
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      builder: (context, child) => IdleTimeoutWrapper(child: child ?? const SizedBox.shrink()),
    );
  }
}
