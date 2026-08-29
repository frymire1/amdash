import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

// Mirrors amdash_core/test/support/pump_app.dart exactly (same rationale in
// its own comments) — ems's own test tree needs its own copy since test/
// directories aren't part of a package's public lib/ and so can't be
// imported cross-package even within this monorepo.

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
