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
import 'services/ambulance_phone_service.dart';

// Extends amdash_core's own RouterRefreshNotifier with the three
// additional providers AmbulanceIdGuard reads — kept local to this app
// (not folded into the shared class) since physician/admin have no use
// for any of them.
class _EmsRouterRefreshNotifier extends ChangeNotifier {
  _EmsRouterRefreshNotifier(Ref ref) {
    _inner = RouterRefreshNotifier(ref)..addListener(notifyListeners);
    // Only the *value* AmbulanceIdGuard actually branches on, not every
    // raw emission — a live Firestore listener (ownOrganizationProvider)
    // commonly re-emits more than once for what's effectively the same
    // data (a local-cache echo, then the server-acknowledged write), and
    // each notifyListeners() call makes GoRouter re-evaluate its whole
    // redirect chain, which can rebuild the *currently displayed* route
    // too even when nothing about the redirect decision changes. Comparing
    // against the guard's own inputs keeps that down to real changes only
    // — this app is the one Flutter e2e failure this session (a rebuild
    // landing between finding and reading a widget, on the shared
    // MFA-enrollment screen — see amdash_patrol_helpers' own
    // _readMfaSecret comment) ever actually happened on, and this is the
    // one extra source of router-driven rebuild churn EMS alone carries
    // that physician/admin don't.
    ref.listen(ambulanceIdProvider, (previous, next) {
      if (previous?.valueOrNull == next.valueOrNull) return;
      notifyListeners();
    });
    ref.listen(ownOrganizationProvider, (previous, next) {
      if (previous?.valueOrNull?.enableMultipleAmbulanceView == next.valueOrNull?.enableMultipleAmbulanceView) {
        return;
      }
      notifyListeners();
    });
    ref.listen(ambulancePhoneProvider, (previous, next) {
      if (previous?.valueOrNull == next.valueOrNull) return;
      notifyListeners();
    });
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
