import 'dart:async';

import 'package:admin/router.dart';
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
  // Same rationale as amdash_core/test/guards/app_guards_test.dart's
  // identical helper: adminRedirect uses ref.read (a one-shot snapshot),
  // so the only race to guard against is an overridden provider not
  // having settled yet before redirect() is called.
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
    final refCaptureProvider = Provider<Ref>((ref) => ref);
    ref = container.read(refCaptureProvider);

    if (!authLoading) await container.read(authStateProvider.future);
    if (!mfaLoading) await container.read(mfaEnrolledFactorsProvider.future);
    if (!profileLoading) await container.read(userProfileProvider.future);
  }

  group('auth tier', () {
    test('no redirect while auth is still loading', () async {
      await setUpContainer(authLoading: true);
      expect(adminRedirect(ref, _stateAt('/')), isNull);
    });

    test('signed out and not already at /login redirects to /login', () async {
      await setUpContainer(user: null);
      expect(adminRedirect(ref, _stateAt('/users')), '/login');
    });

    test('signed out and already at /login stays put', () async {
      await setUpContainer(user: null);
      expect(adminRedirect(ref, _stateAt('/login')), isNull);
    });

    test('signed in but still at /login is bounced to home', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.admin]));
      expect(adminRedirect(ref, _stateAt('/login')), '/');
    });
  });

  group('MFA tier', () {
    test('no redirect while MFA status is still loading', () async {
      await setUpContainer(user: MockUser(), mfaLoading: true);
      expect(adminRedirect(ref, _stateAt('/')), isNull);
    });

    test('no MFA enrolled and not already at /mfa-setup redirects there', () async {
      await setUpContainer(user: MockUser(), hasMfa: false);
      expect(adminRedirect(ref, _stateAt('/')), '/mfa-setup');
    });

    test('no MFA enrolled but already at /mfa-setup stays put', () async {
      await setUpContainer(user: MockUser(), hasMfa: false);
      expect(adminRedirect(ref, _stateAt('/mfa-setup')), isNull);
    });
  });

  group('any-signed-in-user exemption', () {
    test('/user-settings is reachable regardless of role, even with no profile at all', () async {
      await setUpContainer(user: MockUser(), hasMfa: true);
      expect(adminRedirect(ref, _stateAt('/user-settings')), isNull);
    });

    test('/access-denied is reachable regardless of role', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.admin]));
      expect(adminRedirect(ref, _stateAt('/access-denied')), isNull);
    });

    test('no redirect while the profile is still loading', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profileLoading: true);
      expect(adminRedirect(ref, _stateAt('/')), isNull);
    });
  });

  group('landing redirect at /', () {
    test('an admin lands on /users', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.admin]));
      expect(adminRedirect(ref, _stateAt('/')), '/users');
    });

    test('a super-admin (and not also admin) lands on /organizations', () async {
      await setUpContainer(
        user: MockUser(),
        hasMfa: true,
        profile: const UserProfile(role: [UserRole.superAdmin]),
      );
      expect(adminRedirect(ref, _stateAt('/')), '/organizations');
    });

    test('a dual admin+super-admin account lands on /users (admin checked first)', () async {
      await setUpContainer(
        user: MockUser(),
        hasMfa: true,
        profile: const UserProfile(role: [UserRole.admin, UserRole.superAdmin]),
      );
      expect(adminRedirect(ref, _stateAt('/')), '/users');
    });

    test('neither role lands on /access-denied', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.ems]));
      expect(adminRedirect(ref, _stateAt('/')), '/access-denied');
    });

    test('a null profile is treated as lacking every role', () async {
      await setUpContainer(user: MockUser(), hasMfa: true);
      expect(adminRedirect(ref, _stateAt('/')), '/access-denied');
    });
  });

  group('admin-only paths (/users, /settings, /audit-log)', () {
    for (final path in ['/users', '/settings', '/audit-log']) {
      test('$path is reachable by an admin', () async {
        await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.admin]));
        expect(adminRedirect(ref, _stateAt(path)), isNull);
      });

      test('$path redirects a non-admin (even a super-admin) to /access-denied', () async {
        await setUpContainer(
          user: MockUser(),
          hasMfa: true,
          profile: const UserProfile(role: [UserRole.superAdmin]),
        );
        expect(adminRedirect(ref, _stateAt(path)), '/access-denied');
      });
    }
  });

  group('/organizations (super-admin only)', () {
    test('reachable by a super-admin', () async {
      await setUpContainer(
        user: MockUser(),
        hasMfa: true,
        profile: const UserProfile(role: [UserRole.superAdmin]),
      );
      expect(adminRedirect(ref, _stateAt('/organizations')), isNull);
    });

    test('redirects a non-super-admin (even an admin) to /access-denied', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.admin]));
      expect(adminRedirect(ref, _stateAt('/organizations')), '/access-denied');
    });
  });

  group('unlisted paths', () {
    test('fall through with no redirect once auth/MFA/profile all pass', () async {
      await setUpContainer(user: MockUser(), hasMfa: true, profile: const UserProfile(role: [UserRole.admin]));
      expect(adminRedirect(ref, _stateAt('/some-other-route')), isNull);
    });
  });
}
