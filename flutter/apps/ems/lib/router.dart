import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'login_screen.dart';
import 'screens/access_denied_screen.dart';
import 'screens/home_screen.dart';
import 'screens/patient_upload_screen.dart';

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
      requiredRole: UserRole.ems,
    ),
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(path: '/access-denied', builder: (context, state) => const AccessDeniedScreen()),
      GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
      GoRoute(path: '/upload', builder: (context, state) => const PatientUploadScreen()),
      GoRoute(
        path: '/upload/:id',
        builder: (context, state) => PatientUploadScreen(patientId: state.pathParameters['id']),
      ),
    ],
  );
});
