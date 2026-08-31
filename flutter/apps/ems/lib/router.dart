import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/home_screen.dart';
import 'screens/patient_upload_screen.dart';
import 'screens/patient_viewer_screen.dart';
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
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) =>
            fastFadePage(
              context,
              state,
              const AppBackground(
                child: LoginScreen(appName: 'AmDash — EMS', allowedRoles: [UserRole.ems]),
              ),
            ),
      ),
      GoRoute(
        path: '/access-denied',
        pageBuilder: (context, state) =>
            fastFadePage(context, state, const AppBackground(child: AccessDeniedScreen(appName: 'EMS'))),
      ),
      GoRoute(
        path: '/mfa-setup',
        pageBuilder: (context, state) => fastFadePage(context, state, const AppBackground(child: MfaSetupScreen())),
      ),
      // A persistent Scaffold+NavBar shell — kept outside GoRouter's normal
      // per-route page transition, so the navbar no longer visibly
      // unmounts/re-animates on every in-app navigation.
      ShellRoute(
        builder: (context, state, child) =>
            Scaffold(appBar: const NavBar(), body: AppBackground(child: child)),
        routes: [
          GoRoute(
            path: '/user-settings',
            pageBuilder: (context, state) => fastFadePage(context, state, const UserSettingsScreen()),
          ),
          GoRoute(path: '/', pageBuilder: (context, state) => fastFadePage(context, state, const HomeScreen())),
          GoRoute(
            path: '/upload',
            pageBuilder: (context, state) => fastFadePage(context, state, const PatientUploadScreen()),
          ),
          GoRoute(
            path: '/upload/:id',
            pageBuilder: (context, state) =>
                fastFadePage(context, state, PatientUploadScreen(patientId: state.pathParameters['id'])),
          ),
          GoRoute(
            path: '/patient/:id',
            pageBuilder: (context, state) =>
                fastFadePage(context, state, PatientViewerScreen(patientId: state.pathParameters['id']!)),
          ),
        ],
      ),
    ],
  );
});
