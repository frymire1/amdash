import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _FakeGoRouterState extends Mock implements GoRouterState {}

class _FakeMultiFactorInfo extends Mock implements MultiFactorInfo {}

GoRouterState _stateAt(String location) {
  final state = _FakeGoRouterState();
  when(() => state.matchedLocation).thenReturn(location);
  return state;
}

void main() {
  // AppRouteGuard.redirect uses ref.read (a one-shot snapshot), not
  // ref.watch — so unlike the providers themselves, there's no risk of a
  // rebuild racing mid-call here. The only thing to get right is settling
  // each overridden provider *before* calling redirect(), for the same
  // "even Stream.value delivers via microtask, never synchronously"
  // reason documented in hospital_service_test.dart — except for the
  // handful of tests deliberately checking the *loading* branch, which
  // override with a controller/completer that's never completed, so
  // there's nothing to await: the provider is guaranteed to still be
  // AsyncLoading the instant the container is created.
  late ProviderContainer container;
  late Ref ref;

  tearDown(() => container.dispose());

  Future<void> setUpContainer({
    User? user,
    bool authLoading = false,
    bool hasMfa = false,
    bool mfaLoading = false,
    UserProfile? profile,
    bool profileLoading = false,
  }) async {
    container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(
          (ref) => authLoading ? StreamController<User?>().stream : Stream.value(user),
        ),
        mfaEnrolledFactorsProvider.overrideWith(
          (ref) => mfaLoading
              ? Completer<List<MultiFactorInfo>>().future
              : Future.value(hasMfa ? [_FakeMultiFactorInfo()] : const []),
        ),
        userProfileProvider.overrideWith(
          (ref) => profileLoading ? StreamController<UserProfile?>().stream : Stream.value(profile),
        ),
      ],
    );
    // Capture a real Ref backed by this container — AppRouteGuard.redirect
    // needs one, and ProviderContainer itself isn't a Ref.
    final refCaptureProvider = Provider<Ref>((ref) => ref);
    ref = container.read(refCaptureProvider);

    if (!authLoading) await container.read(authStateProvider.future);
    if (!mfaLoading) await container.read(mfaEnrolledFactorsProvider.future);
    if (!profileLoading) await container.read(userProfileProvider.future);
  }

  group('auth tier', () {
    test('no redirect while auth is still loading', () async {
      await setUpContainer(authLoading: true);
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician],
      );
      expect(result, isNull);
    });

    test('signed out and not already at /login redirects to /login', () async {
      await setUpContainer(user: null);
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician],
      );
      expect(result, '/login');
    });

    test('signed out and already at /login stays put', () async {
      await setUpContainer(user: null);
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/login'),
        requiredRoles: const [UserRole.physician],
      );
      expect(result, isNull);
    });

    test('signed in but still at /login is bounced to home', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.physician]));
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/login'),
        requiredRoles: const [UserRole.physician],
      );
      expect(result, '/');
    });

    test('respects a custom loginPath/homePath', () async {
      await setUpContainer(user: null);
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/custom-login'),
        requiredRoles: const [UserRole.physician],
        loginPath: '/custom-login',
      );
      expect(result, isNull);
    });
  });

  group('MFA tier', () {
    test('no redirect while MFA status is still loading', () async {
      await setUpContainer(user: MockUser(), mfaLoading: true);
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician],
      );
      expect(result, isNull);
    });

    test('no MFA enrolled and not already at /mfa-setup redirects there', () async {
      await setUpContainer(user: MockUser(), hasMfa: false);
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician],
      );
      expect(result, '/mfa-setup');
    });

    test('no MFA enrolled but already at /mfa-setup stays put', () async {
      await setUpContainer(user: MockUser(), hasMfa: false);
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/mfa-setup'),
        requiredRoles: const [UserRole.physician],
      );
      expect(result, isNull);
    });

    test('MFA enrolled proceeds past this tier to the role check', () async {
      await setUpContainer(
        user: MockUser(),
        hasMfa: true,
        profile: const UserProfile(role: [UserRole.ems]),
      );
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician],
      );
      // Reaches (and fails) the role check, not the MFA one — proves MFA
      // was satisfied rather than short-circuiting here.
      expect(result, '/access-denied');
    });

    test('requireMfa: false skips the tier entirely, even with no factors enrolled', () async {
      await setUpContainer(user: MockUser(), hasMfa: false, profile: const UserProfile(role: [UserRole.physician]));
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician],
        requireMfa: false,
      );
      expect(result, isNull);
    });
  });

  group('role tier', () {
    test('no redirect while the profile is still loading', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profileLoading: true);
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician],
      );
      expect(result, isNull);
    });

    test('a null profile is treated as lacking every role', () async {
      await setUpContainer(user: MockUser(), hasMfa: true);
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician],
      );
      expect(result, '/access-denied');
    });

    test('missing every required role redirects to /access-denied', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.ems]));
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician, UserRole.nurse],
      );
      expect(result, '/access-denied');
    });

    test('missing every required role but already at /access-denied stays put', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.ems]));
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/access-denied'),
        requiredRoles: const [UserRole.physician],
      );
      expect(result, isNull);
    });

    test('having any one of several required roles is enough', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.nurse]));
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician, UserRole.nurse],
      );
      expect(result, isNull);
    });
  });

  group('work-location tier', () {
    test('not required by default — a role match alone is enough', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.physician]));
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician],
      );
      expect(result, isNull);
    });

    test('required and missing (null) redirects to /work-location', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.physician]));
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician],
        requireWorkLocation: true,
      );
      expect(result, '/work-location');
    });

    test('required and set to an empty string is treated the same as missing', () async {
      await setUpContainer(
        user: MockUser(),
        hasMfa: true,
        profile: const UserProfile(role: [UserRole.physician], workLocation: ''),
      );
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/'),
        requiredRoles: const [UserRole.physician],
        requireWorkLocation: true,
      );
      expect(result, '/work-location');
    });

    test('required, missing, but already at /work-location stays put', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.physician]));
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/work-location'),
        requiredRoles: const [UserRole.physician],
        requireWorkLocation: true,
      );
      expect(result, isNull);
    });

    test('required and present allows navigation through', () async {
      await setUpContainer(
        user: MockUser(),
        hasMfa: true,
        profile: const UserProfile(role: [UserRole.physician], workLocation: 'General Hospital'),
      );
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/patients'),
        requiredRoles: const [UserRole.physician],
        requireWorkLocation: true,
      );
      expect(result, isNull);
    });

    test('required, present, but still sitting at /work-location self-heals to home', () async {
      // A cache-flicker self-heal case (see the source's own comment): a
      // freshly re-attached listener's first (cached) snapshot can
      // transiently miss a since-added field, bouncing the guard onto
      // /work-location even though a location genuinely exists — nothing
      // else ever forwards back out of it once the corrected value
      // arrives, so this tier does it itself.
      await setUpContainer(
        user: MockUser(),
        hasMfa: true,
        profile: const UserProfile(role: [UserRole.physician], workLocation: 'General Hospital'),
      );
      final result = AppRouteGuard.redirect(
        ref: ref,
        state: _stateAt('/work-location'),
        requiredRoles: const [UserRole.physician],
        requireWorkLocation: true,
      );
      expect(result, '/');
    });
  });

  group('RouterRefreshNotifier', () {
    test('calls notifyListeners whenever authState/userProfile/mfaEnrolledFactors changes', () async {
      final authController = StreamController<User?>.broadcast();
      final profileController = StreamController<UserProfile?>.broadcast();
      final testContainer = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith((ref) => authController.stream),
          userProfileProvider.overrideWith((ref) => profileController.stream),
          mfaEnrolledFactorsProvider.overrideWith((ref) => Future.value(const [])),
        ],
      );
      addTearDown(testContainer.dispose);
      addTearDown(authController.close);
      addTearDown(profileController.close);

      final refCaptureProvider = Provider<Ref>((ref) => ref);
      final testRef = testContainer.read(refCaptureProvider);

      // Broadcast StreamControllers drop events pushed before anything's
      // subscribed — container.listen forces that subscription to exist
      // synchronously, before pushing the first value, unlike
      // container.read(provider.future) alone (which only subscribes as
      // a side effect, too late for a value already pushed).
      testContainer.listen(authStateProvider, (_, _) {});
      testContainer.listen(userProfileProvider, (_, _) {});

      // Let every provider settle once before constructing the notifier —
      // RouterRefreshNotifier's own constructor calls ref.listen, which
      // (unlike ref.read) only fires on a *subsequent* change, not the
      // provider's initial value — so this first settle shouldn't count
      // as a notification, only what happens after.
      authController.add(null);
      profileController.add(null);
      await testContainer.read(authStateProvider.future);
      await testContainer.read(userProfileProvider.future);
      await testContainer.read(mfaEnrolledFactorsProvider.future);

      final notifier = RouterRefreshNotifier(testRef);
      addTearDown(notifier.dispose);
      var notifyCount = 0;
      notifier.addListener(() => notifyCount++);

      authController.add(MockUser());
      await Future<void>.delayed(Duration.zero);
      expect(notifyCount, greaterThan(0));

      final afterAuth = notifyCount;
      profileController.add(const UserProfile(role: [UserRole.physician]));
      await Future<void>.delayed(Duration.zero);
      expect(notifyCount, greaterThan(afterAuth));
    });
  });
}
