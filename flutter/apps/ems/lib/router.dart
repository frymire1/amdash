import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'guards/ambulance_id_guard.dart';
import 'screens/ambulance_id_screen.dart';
import 'screens/home_screen.dart';
import 'screens/patient_upload_screen.dart';
import 'screens/patient_viewer_screen.dart';
import 'screens/user_settings_screen.dart';
import 'services/ambulance_id_service.dart';

// Extends amdash_core's own RouterRefreshNotifier with the two additional
// providers AmbulanceIdGuard reads — kept local to this app (not folded
// into the shared class) since physician/admin have no use for either.
class _EmsRouterRefreshNotifier extends ChangeNotifier {
  _EmsRouterRefreshNotifier(Ref ref) {
    _inner = RouterRefreshNotifier(ref)..addListener(notifyListeners);
    ref.listen(ambulanceIdProvider, (_, _) => notifyListeners());
    ref.listen(ownOrganizationProvider, (_, _) => notifyListeners());
  }

  late final RouterRefreshNotifier _inner;

  @override
  void dispose() {
    _inner.dispose();
    super.dispose();
  }
}

/// Mirrors `apps/ems/src/app/app.routes.ts`'s route table and guard chain
/// (`authGuard` -> `emsAppGuard`; no `workLocationGuard` — that only
/// applies to physician/nurse), plus an EMS-only `AmbulanceIdGuard` tier
/// (see that class's own doc comment) that Angular predates entirely.
final appRouterProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = _EmsRouterRefreshNotifier(ref);
  ref.onDispose(refreshNotifier.dispose);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      final baseRedirect = AppRouteGuard.redirect(ref: ref, state: state, requiredRoles: const [UserRole.ems]);
      if (baseRedirect != null) return baseRedirect;
      return AmbulanceIdGuard.redirect(ref: ref, state: state);
    },
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
      GoRoute(
        path: '/ambulance-id',
        pageBuilder: (context, state) =>
            fastFadePage(context, state, const AppBackground(child: AmbulanceIdScreen())),
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
