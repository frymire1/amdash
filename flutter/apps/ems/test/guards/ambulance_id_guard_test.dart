import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:ems/guards/ambulance_id_guard.dart';
import 'package:ems/services/ambulance_id_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _FakeGoRouterState extends Mock implements GoRouterState {}

GoRouterState _stateAt(String location) {
  final state = _FakeGoRouterState();
  when(() => state.matchedLocation).thenReturn(location);
  return state;
}

void main() {
  // Same rationale as admin's router_test.dart: AmbulanceIdGuard.redirect
  // uses ref.read (a one-shot snapshot), so the only race to guard against
  // is an overridden provider not having settled yet before redirect() is
  // called.
  late ProviderContainer container;
  late Ref ref;

  tearDown(() => container.dispose());

  Future<void> setUpContainer({
    bool orgLoading = false,
    Organization? organization,
    bool ambulanceIdLoading = false,
    String? ambulanceId,
  }) async {
    container = ProviderContainer(
      overrides: [
        ownOrganizationProvider.overrideWith(
          (ref) => orgLoading ? StreamController<Organization?>().stream : Stream.value(organization),
        ),
        ambulanceIdProvider.overrideWith(
          (ref) => ambulanceIdLoading ? Completer<String?>().future : Future.value(ambulanceId),
        ),
      ],
    );
    final refCaptureProvider = Provider<Ref>((ref) => ref);
    ref = container.read(refCaptureProvider);

    if (!orgLoading) await container.read(ownOrganizationProvider.future);
    if (!ambulanceIdLoading) await container.read(ambulanceIdProvider.future);
  }

  group('org tier', () {
    test('no redirect while org is still loading', () async {
      await setUpContainer(orgLoading: true);
      expect(AmbulanceIdGuard.redirect(ref: ref, state: _stateAt('/')), isNull);
    });

    test('feature disabled (null org) never redirects, even off /ambulance-id', () async {
      await setUpContainer();
      expect(AmbulanceIdGuard.redirect(ref: ref, state: _stateAt('/')), isNull);
    });

    test('feature disabled (flag explicitly false) never redirects', () async {
      await setUpContainer(
        organization: const Organization(id: 'org1', name: 'Org', enableMultipleAmbulanceView: false),
      );
      expect(AmbulanceIdGuard.redirect(ref: ref, state: _stateAt('/')), isNull);
    });

    test('feature disabled leaves /ambulance-id itself reachable with no redirect', () async {
      await setUpContainer();
      expect(AmbulanceIdGuard.redirect(ref: ref, state: _stateAt('/ambulance-id')), isNull);
    });
  });

  group('ambulance ID tier (feature enabled)', () {
    test('no redirect while ambulance ID is still loading', () async {
      await setUpContainer(
        organization: const Organization(id: 'org1', name: 'Org', enableMultipleAmbulanceView: true),
        ambulanceIdLoading: true,
      );
      expect(AmbulanceIdGuard.redirect(ref: ref, state: _stateAt('/')), isNull);
    });

    test('unset and not already at /ambulance-id redirects there', () async {
      await setUpContainer(organization: const Organization(id: 'org1', name: 'Org', enableMultipleAmbulanceView: true));
      expect(AmbulanceIdGuard.redirect(ref: ref, state: _stateAt('/')), '/ambulance-id');
    });

    test('empty string is treated as unset', () async {
      await setUpContainer(
        organization: const Organization(id: 'org1', name: 'Org', enableMultipleAmbulanceView: true),
        ambulanceId: '',
      );
      expect(AmbulanceIdGuard.redirect(ref: ref, state: _stateAt('/')), '/ambulance-id');
    });

    test('unset and already at /ambulance-id stays put', () async {
      await setUpContainer(organization: const Organization(id: 'org1', name: 'Org', enableMultipleAmbulanceView: true));
      expect(AmbulanceIdGuard.redirect(ref: ref, state: _stateAt('/ambulance-id')), isNull);
    });

    test('set and sitting on /ambulance-id self-heals back to home', () async {
      await setUpContainer(
        organization: const Organization(id: 'org1', name: 'Org', enableMultipleAmbulanceView: true),
        ambulanceId: 'Unit 5',
      );
      expect(AmbulanceIdGuard.redirect(ref: ref, state: _stateAt('/ambulance-id')), '/');
    });

    test('set and elsewhere stays put', () async {
      await setUpContainer(
        organization: const Organization(id: 'org1', name: 'Org', enableMultipleAmbulanceView: true),
        ambulanceId: 'Unit 5',
      );
      expect(AmbulanceIdGuard.redirect(ref: ref, state: _stateAt('/upload')), isNull);
    });
  });

  group('custom paths', () {
    test('respects a non-default ambulanceIdPath/homePath', () async {
      await setUpContainer(organization: const Organization(id: 'org1', name: 'Org', enableMultipleAmbulanceView: true));
      expect(
        AmbulanceIdGuard.redirect(
          ref: ref,
          state: _stateAt('/'),
          ambulanceIdPath: '/custom-id',
          homePath: '/custom-home',
        ),
        '/custom-id',
      );
    });
  });
}
