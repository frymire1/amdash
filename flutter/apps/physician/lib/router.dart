import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/main_view_screen.dart';
import 'screens/user_settings_screen.dart';

/// Mirrors `apps/physician/src/app/app.routes.ts`'s route table and guard
/// chain: `authGuard` -> `physicianAppGuard` (physician|nurse) ->
/// `workLocationGuard`.
final appRouterProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = RouterRefreshNotifier(ref);
  ref.onDispose(refreshNotifier.dispose);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: refreshNotifier,
    redirect: (context, state) => AppRouteGuard.redirect(
      ref: ref,
      state: state,
      requiredRoles: const [UserRole.physician, UserRole.nurse],
      requireWorkLocation: true,
    ),
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen(appName: 'AmDash — Physician')),
      GoRoute(
        path: '/access-denied',
        builder: (context, state) => const AccessDeniedScreen(appName: 'Physician'),
      ),
      GoRoute(path: '/work-location', builder: (context, state) => const WorkLocationScreen()),
      // A persistent Scaffold+NavBar shell — kept outside GoRouter's normal
      // per-route page transition, so the navbar no longer visibly
      // unmounts/re-animates on every in-app navigation (only /login,
      // /access-denied, /work-location are exempt, since those aren't
      // "using the app" yet).
      ShellRoute(
        builder: (context, state, child) => Scaffold(appBar: const NavBar(), body: child),
        routes: [
          GoRoute(path: '/user-settings', builder: (context, state) => const UserSettingsScreen()),
          GoRoute(path: '/', builder: (context, state) => const MainViewScreen()),
        ],
      ),
    ],
  );
});
