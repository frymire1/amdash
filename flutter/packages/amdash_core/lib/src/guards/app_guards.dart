import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_service.dart';
import '../auth/user_profile_service.dart';
import '../models/user_profile.dart';

/// Mirrors `libs/auth/src/lib/guards/auth.guard.ts`'s 3-tier redirect
/// chain (auth -> role -> work-location), each waiting for the relevant
/// "loaded" state before deciding, same order as the Angular guards.
/// `requiredRoles` matches `physicianAppGuard`/`emsAppGuard`/`adminGuard`
/// (`roleGuard(...allowedRoles)` in the Angular source — a user needs only
/// one of them, e.g. physician's own guard accepts `physician` OR `nurse`);
/// pass `requireWorkLocation: true` for apps where `workLocationGuard`
/// also applies (physician/nurse only).
class AppRouteGuard {
  const AppRouteGuard._();

  static String? redirect({
    required Ref ref,
    required GoRouterState state,
    required List<UserRole> requiredRoles,
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
    if (profile == null || !profile.hasAnyRole(requiredRoles)) {
      return state.matchedLocation == accessDeniedPath ? null : accessDeniedPath;
    }

    if (requireWorkLocation) {
      final hasWorkLocation = profile.workLocation != null && profile.workLocation!.isNotEmpty;
      if (!hasWorkLocation) {
        return state.matchedLocation == workLocationPath ? null : workLocationPath;
      }
      // A freshly (re)attached Firestore listener — e.g. after an auth
      // token refresh recreates userProfileProvider — emits its first
      // snapshot from the local cache before the server-confirmed one, and
      // that first cached read can transiently miss a since-added field.
      // That can bounce this guard onto workLocationPath even though a
      // work location genuinely exists; without this, nothing would ever
      // send it back once the corrected snapshot arrives, since the block
      // above only *blocks* entry, it never *forwards* out again. Mirrors
      // WorkLocationScreen's own post-submit `context.go('/')` for the
      // normal case, but also self-heals this cache-flicker case.
      if (state.matchedLocation == workLocationPath) {
        return homePath;
      }
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
