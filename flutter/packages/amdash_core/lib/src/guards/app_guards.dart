import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_service.dart';
import '../auth/user_profile_service.dart';
import '../models/user_profile.dart';

/// Mirrors `libs/auth/src/lib/guards/auth.guard.ts`'s 3-tier redirect
/// chain (auth -> role -> work-location), each waiting for the relevant
/// "loaded" state before deciding, same order as the Angular guards.
/// `requiredRole` matches `physicianAppGuard`/`emsAppGuard`/`adminGuard`;
/// pass `requireWorkLocation: true` for apps where `workLocationGuard`
/// also applies (physician/nurse only).
class AppRouteGuard {
  const AppRouteGuard._();

  static String? redirect({
    required Ref ref,
    required GoRouterState state,
    required UserRole requiredRole,
    bool requireWorkLocation = false,
    String loginPath = '/login',
    String accessDeniedPath = '/access-denied',
    String workLocationPath = '/work-location',
    String homePath = '/',
  }) {
    final authState = ref.read(authStateProvider);
    if (authState.isLoading) return null;

    final user = authState.valueOrNull;
    final isLoggingIn = state.matchedLocation == loginPath;

    if (user == null) {
      return isLoggingIn ? null : loginPath;
    }
    if (isLoggingIn) return homePath;

    final profileState = ref.read(userProfileProvider);
    if (profileState.isLoading) return null;

    final profile = profileState.valueOrNull;
    if (profile == null || !profile.hasRole(requiredRole)) {
      return state.matchedLocation == accessDeniedPath ? null : accessDeniedPath;
    }

    if (requireWorkLocation &&
        (profile.workLocation == null || profile.workLocation!.isEmpty)) {
      return state.matchedLocation == workLocationPath ? null : workLocationPath;
    }

    return null;
  }
}

/// Bridges Riverpod's auth/profile stream state to a `Listenable` so
/// go_router's `refreshListenable` re-evaluates `redirect` whenever either
/// changes — the Flutter equivalent of the Angular guards' own
/// `toObservable(signal)` reactivity.
class RouterRefreshNotifier extends ChangeNotifier {
  RouterRefreshNotifier(Ref ref) {
    ref.listen(authStateProvider, (_, _) => notifyListeners());
    ref.listen(userProfileProvider, (_, _) => notifyListeners());
  }
}
