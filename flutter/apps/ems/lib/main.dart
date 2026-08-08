import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Required before any FlutterForegroundTask.startService/sendDataToTask
  // calls — sets up the port the background isolate (see
  // services/ems_tracking_task_handler.dart) uses to talk back to this one.
  // flutter_foreground_task has no web implementation at all (see
  // ems_tracking_service.dart's header comment) — calling this
  // unconditionally crashes app boot on web.
  if (!kIsWeb) {
    FlutterForegroundTask.initCommunicationPort();
  }

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
    );
  }
}
