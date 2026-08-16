import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/audit_log_screen.dart';
import 'screens/organization_management_screen.dart';
import 'screens/organization_settings_screen.dart';
import 'screens/user_management_screen.dart';
import 'screens/user_settings_screen.dart';
import 'widgets/nav_bar.dart';

/// Mirrors `apps/admin/src/app/app.routes.ts`'s route table and guard
/// chain — genuinely different shape from EMS/physician's single
/// required-role-per-app model, so this doesn't reuse [AppRouteGuard]:
/// `/users`/`/settings`/`/audit-log` require `admin` (hospital management
/// lives inside `/settings` now, not its own route), `/organizations`
/// requires `super-admin` (a dual-role account can reach both), and `''`
/// resolves via a landing redirect (mirrors `landing.guard.ts`) rather than
/// rendering anything itself. There's also no `workLocationGuard` step at
/// all — admin skips that entirely, unlike physician.
const _adminOnlyPaths = {'/users', '/settings', '/audit-log'};

String? _adminRedirect(Ref ref, GoRouterState state) {
  final authState = ref.read(authStateProvider);
  if (authState.isLoading) return null;

  final user = authState.valueOrNull;
  final isLoggingIn = state.matchedLocation == '/login';

  if (user == null) {
    return isLoggingIn ? null : '/login';
  }
  if (isLoggingIn) return '/';

  final profileState = ref.read(userProfileProvider);
  if (profileState.isLoading) return null;
  final profile = profileState.valueOrNull;

  // No role requirement on these — reachable by any signed-in user.
  if (state.matchedLocation == '/user-settings' || state.matchedLocation == '/access-denied') {
    return null;
  }

  final isAdmin = profile?.hasRole(UserRole.admin) ?? false;
  final isSuperAdmin = profile?.hasRole(UserRole.superAdmin) ?? false;

  if (state.matchedLocation == '/') {
    if (isAdmin) return '/users';
    if (isSuperAdmin) return '/organizations';
    return '/access-denied';
  }

  if (_adminOnlyPaths.contains(state.matchedLocation)) {
    return isAdmin ? null : '/access-denied';
  }

  if (state.matchedLocation == '/organizations') {
    return isSuperAdmin ? null : '/access-denied';
  }

  return null;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = RouterRefreshNotifier(ref);
  ref.onDispose(refreshNotifier.dispose);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: refreshNotifier,
    redirect: (context, state) => _adminRedirect(ref, state),
    routes: [
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) =>
            fastFadePage(context, state, const AppBackground(child: LoginScreen(appName: 'AmDash — Admin'))),
      ),
      GoRoute(
        path: '/access-denied',
        pageBuilder: (context, state) =>
            fastFadePage(context, state, const AppBackground(child: AccessDeniedScreen(appName: 'Admin'))),
      ),
      // Pure redirect target, same as `landing.guard.ts` — never renders
      // its real content. While the profile is still loading,
      // _adminRedirect returns null (stays put) rather than redirecting
      // yet, so this still briefly builds; a real management screen here
      // (rather than this bare placeholder) would mount, kick off its
      // async initState fetch, and then get disposed moments later once
      // the profile resolves and redirects onward — a real
      // "setState() called after dispose()" this app hit during
      // verification. Kept outside the shell below since it's never
      // actually seen — no navbar needed for an instant redirect.
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      // A persistent Scaffold+AdminNavBar shell — kept outside GoRouter's
      // normal per-route page transition, so the navbar no longer visibly
      // unmounts/re-animates on every in-app navigation.
      ShellRoute(
        builder: (context, state, child) =>
            Scaffold(appBar: const AdminNavBar(), body: AppBackground(child: child)),
        routes: [
          GoRoute(
            path: '/user-settings',
            pageBuilder: (context, state) => fastFadePage(context, state, const UserSettingsScreen()),
          ),
          GoRoute(
            path: '/users',
            pageBuilder: (context, state) => fastFadePage(context, state, const UserManagementScreen()),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) => fastFadePage(context, state, const OrganizationSettingsScreen()),
          ),
          GoRoute(
            path: '/organizations',
            pageBuilder: (context, state) => fastFadePage(context, state, const OrganizationManagementScreen()),
          ),
          GoRoute(
            path: '/audit-log',
            pageBuilder: (context, state) => fastFadePage(context, state, const AuditLogScreen()),
          ),
        ],
      ),
    ],
  );
});
