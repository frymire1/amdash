import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/home_screen.dart';
import 'screens/patient_upload_screen.dart';
import 'screens/user_settings_screen.dart';

/// Mirrors `apps/ems/src/app/app.routes.ts`'s route table and guard chain
/// (`authGuard` -> `emsAppGuard`; no `workLocationGuard` — that only
/// applies to physician/nurse).
final appRouterProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = RouterRefreshNotifier(ref);
  ref.onDispose(refreshNotifier.dispose);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: refreshNotifier,
    redirect: (context, state) => AppRouteGuard.redirect(
      ref: ref,
      state: state,
      requiredRoles: const [UserRole.ems],
    ),
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen(appName: 'AmDash — EMS')),
      GoRoute(
        path: '/access-denied',
        builder: (context, state) => const AccessDeniedScreen(appName: 'EMS'),
      ),
      // A persistent Scaffold+NavBar shell — kept outside GoRouter's normal
      // per-route page transition, so the navbar no longer visibly
      // unmounts/re-animates on every in-app navigation.
      ShellRoute(
        builder: (context, state, child) => Scaffold(appBar: const NavBar(), body: child),
        routes: [
          GoRoute(path: '/user-settings', builder: (context, state) => const UserSettingsScreen()),
          GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
          GoRoute(path: '/upload', builder: (context, state) => const PatientUploadScreen()),
          GoRoute(
            path: '/upload/:id',
            builder: (context, state) => PatientUploadScreen(patientId: state.pathParameters['id']),
          ),
        ],
      ),
    ],
  );
});
