import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Pumps [child] the way every real screen in this repo is actually
/// mounted — confirmed directly against all three apps' own `main.dart`:
/// `ProviderScope` -> `MaterialApp`(.router) using this package's own real
/// `buildLightTheme()`/`buildDarkTheme()`. `themeModeProvider`/
/// `IdleTimeoutWrapper` are each app's own shell wiring, not part of
/// amdash_core's own widget surface, and are deliberately not part of
/// this harness.
///
/// [routes] is only needed for a widget that itself calls
/// `context.go`/`.push` — `context.go` resolves `GoRouter.of(context)`
/// from the tree, and there's no public seam to fake that, so a real,
/// minimal [GoRouter] is mounted instead of a mock. The default route
/// ('/') renders a keyed sentinel ([pumpAppHomeKey]) so a test can assert
/// "navigation reached home" via `find.byKey` without needing a real
/// destination screen.
final pumpAppHomeKey = UniqueKey();

Future<void> pumpApp(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
  Brightness brightness = Brightness.light,
  Map<String, WidgetBuilder>? routes,
  String initialLocation = '/',
}) async {
  final theme = brightness == Brightness.dark ? buildDarkTheme() : buildLightTheme();

  if (routes == null) {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        // Every real screen in this repo renders inside a Scaffold (either
        // its own, or the authenticated shell's) — confirmed for real that
        // a bare `home: child` with no Material ancestor at all breaks any
        // InkWell-based widget (e.g. PatientInfoChip's trend-icon tap
        // target) with "No Material widget found." A screen that already
        // builds its own Scaffold (e.g. AccessDeniedScreen) just ends up
        // harmlessly double-nested.
        child: MaterialApp(theme: theme, home: Scaffold(body: child)),
      ),
    );
    return;
  }

  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', builder: (context, state) => SizedBox(key: pumpAppHomeKey)),
      for (final entry in routes.entries)
        if (entry.key != '/') GoRoute(path: entry.key, builder: (context, state) => entry.value(context)),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(overrides: overrides, child: MaterialApp.router(theme: theme, routerConfig: router)),
  );
}
