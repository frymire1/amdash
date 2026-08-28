// See this file's own EmsLocationController-with-a-controlled-mock group
// for why Query/QuerySnapshot/QueryDocumentSnapshot need to be mocked
// directly there — same rationale as
// ems/test/services/patient_upload_service_test.dart's identical
// ignore_for_file comment.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:physician/services/ems_location_service.dart';

class _MockWidgetRef extends Mock implements WidgetRef {}

class _MockFirestore extends Mock implements FirebaseFirestore {}

class _MockQuery extends Mock implements Query<Map<String, dynamic>> {}

class _MockQuerySnapshot extends Mock implements QuerySnapshot<Map<String, dynamic>> {}

class _MockQueryDocSnapshot extends Mock implements QueryDocumentSnapshot<Map<String, dynamic>> {}

QueryDocumentSnapshot<Map<String, dynamic>> _locationDoc(
  String patientId, {
  required double latitude,
  required double longitude,
}) {
  final doc = _MockQueryDocSnapshot();
  when(() => doc.data()).thenReturn({
    'organizationId': 'org-1',
    'active': true,
    'patientId': patientId,
    'updatedAt': Timestamp.now(),
    'latitude': latitude,
    'longitude': longitude,
  });
  return doc;
}

QuerySnapshot<Map<String, dynamic>> _querySnapshot(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
  final snapshot = _MockQuerySnapshot();
  when(() => snapshot.docs).thenReturn(docs);
  return snapshot;
}

// EmsLocationController is a Notifier, not a Stream/FutureProvider — no
// `.future` to await. Waits for the *next* state matching [predicate],
// checking the current value first so an already-satisfied predicate
// resolves synchronously rather than waiting for a state change that will
// never come.
Future<EmsLocationState> _waitUntil(
  ProviderContainer container,
  bool Function(EmsLocationState) predicate,
) async {
  final current = container.read(emsLocationProvider);
  if (predicate(current)) return current;

  final completer = Completer<EmsLocationState>();
  late final ProviderSubscription<EmsLocationState> sub;
  sub = container.listen(emsLocationProvider, (previous, next) {
    if (predicate(next) && !completer.isCompleted) {
      completer.complete(next);
      sub.close();
    }
  });
  return completer.future;
}

// Unlike _waitUntil, this doesn't check a predicate on *content* — it
// subscribes first (so nothing pushed by [trigger] can be missed, same
// "listen before pushing" rule as a broadcast StreamController elsewhere
// in this repo's tests), then reports the very next state Riverpod
// actually delivers, whatever it is. Needed for the "stays the same
// because nothing changed" case below, where waiting on a predicate over
// the resulting *value* can't distinguish "the second snapshot was
// processed and correctly left this unchanged" from "the second
// snapshot was never delivered/processed at all".
Future<EmsLocationState> _waitForNextEmission(ProviderContainer container, void Function() trigger) {
  final completer = Completer<EmsLocationState>();
  late final ProviderSubscription<EmsLocationState> sub;
  sub = container.listen(emsLocationProvider, (previous, next) {
    if (!completer.isCompleted) {
      completer.complete(next);
      sub.close();
    }
  });
  trigger();
  return completer.future;
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<ProviderContainer> containerFor(UserProfile? profile) async {
    final container = ProviderContainer(
      overrides: [
        firestoreProvider.overrideWithValue(firestore),
        userProfileProvider.overrideWith((ref) => Stream.value(profile)),
      ],
    );
    // build() itself reads userProfileProvider synchronously (not via a
    // fireImmediately listener — see that method's own comment for why),
    // so it needs userProfileProvider already settled or it'll compute
    // its initial state from a still-loading value instead of the real
    // one — same settling race as every other provider test in this repo.
    await container.read(userProfileProvider.future);
    return container;
  }

  group('EmsLocationController', () {
    test('no organization -> hasLoadedOnce true immediately, no query ever issued', () async {
      final container = await containerFor(null);
      addTearDown(container.dispose);

      final state = await _waitUntil(container, (s) => s.hasLoadedOnce);
      expect(state.info, isEmpty);
    });

    test('maps a fresh location fix to EmsTrackingStatus.active', () async {
      await firestore
          .collection('patients')
          .doc('patient-1')
          .collection('location')
          .doc('current')
          .set({
            'organizationId': 'org-1',
            'active': true,
            'patientId': 'patient-1',
            'updatedAt': Timestamp.now(),
            'latitude': 45.4,
            'longitude': -75.7,
          });

      const profile = UserProfile(role: [UserRole.physician], organizationId: 'org-1');
      final container = await containerFor(profile);
      addTearDown(container.dispose);

      final state = await _waitUntil(container, (s) => s.hasLoadedOnce);
      final info = state.info['patient-1']!;
      expect(info.status, EmsTrackingStatus.active);
      expect(info.location!.latitude, 45.4);
      expect(info.location!.longitude, -75.7);
    });

    test('a fix already older than the staleness threshold maps to EmsTrackingStatus.stale', () async {
      final staleTimestamp = Timestamp.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch - 60000,
      );
      await firestore
          .collection('patients')
          .doc('patient-1')
          .collection('location')
          .doc('current')
          .set({
            'organizationId': 'org-1',
            'active': true,
            'patientId': 'patient-1',
            'updatedAt': staleTimestamp,
          });

      const profile = UserProfile(role: [UserRole.physician], organizationId: 'org-1');
      final container = await containerFor(profile);
      addTearDown(container.dispose);

      final state = await _waitUntil(container, (s) => s.hasLoadedOnce);
      expect(state.info['patient-1']!.status, EmsTrackingStatus.stale);
    });

    test('only matches this organizationId, scoped across the whole collection group', () async {
      await firestore
          .collection('patients')
          .doc('patient-1')
          .collection('location')
          .doc('current')
          .set({'organizationId': 'org-1', 'active': true, 'patientId': 'patient-1', 'updatedAt': Timestamp.now()});
      await firestore
          .collection('patients')
          .doc('patient-2')
          .collection('location')
          .doc('current')
          .set({'organizationId': 'org-2', 'active': true, 'patientId': 'patient-2', 'updatedAt': Timestamp.now()});

      const profile = UserProfile(role: [UserRole.physician], organizationId: 'org-1');
      final container = await containerFor(profile);
      addTearDown(container.dispose);

      final state = await _waitUntil(container, (s) => s.hasLoadedOnce);
      expect(state.info.containsKey('patient-1'), true);
      expect(state.info.containsKey('patient-2'), false);
    });

    test('re-subscribes to the newly-scoped query when userProfileProvider emits a genuinely later '
        "change (not just build()'s own initial synchronous read)", () async {
      await firestore
          .collection('patients')
          .doc('patient-1')
          .collection('location')
          .doc('current')
          .set({'organizationId': 'org-1', 'active': true, 'patientId': 'patient-1', 'updatedAt': Timestamp.now()});
      await firestore
          .collection('patients')
          .doc('patient-2')
          .collection('location')
          .doc('current')
          .set({'organizationId': 'org-2', 'active': true, 'patientId': 'patient-2', 'updatedAt': Timestamp.now()});

      final profileController = StreamController<UserProfile?>();
      addTearDown(profileController.close);
      final container = ProviderContainer(
        overrides: [
          firestoreProvider.overrideWithValue(firestore),
          userProfileProvider.overrideWith((ref) => profileController.stream),
        ],
      );
      addTearDown(container.dispose);

      profileController.add(const UserProfile(role: [UserRole.physician], organizationId: 'org-1'));
      await container.read(userProfileProvider.future);

      final orgOneState = await _waitUntil(container, (s) => s.hasLoadedOnce);
      expect(orgOneState.info.containsKey('patient-1'), true);
      expect(orgOneState.info.containsKey('patient-2'), false);

      // A genuine later change — e.g. the caller's own org changed — goes
      // through ref.listen (this class's own _resubscribe), not build().
      // Not _waitForNextEmission: _resubscribe's own synchronous `state =`
      // assignment (the reset-to-empty EmsLocationState) is itself the
      // *first* post-trigger emission — the org-2-populated one only
      // arrives after that, once the new query's own first snapshot
      // (async) is delivered.
      profileController.add(const UserProfile(role: [UserRole.physician], organizationId: 'org-2'));
      final orgTwoState = await _waitUntil(container, (s) => s.info.containsKey('patient-2'));
      expect(orgTwoState.info.containsKey('patient-2'), true);
      // _latest is reset on every resubscribe — org-1's patient doesn't
      // carry over into the new org's state.
      expect(orgTwoState.info.containsKey('patient-1'), false);
    });
  });

  // fake_cloud_firestore's collectionGroup(...) query is a one-shot
  // snapshot of whatever matched at the moment it was constructed —
  // confirmed for real via a throwaway probe test that updating a
  // document already included in a live collectionGroup query's results
  // never re-fires its .snapshots() listener at all (ordinary
  // single-collection queries, used everywhere else in this repo's
  // tests, don't have this gap). There's no way to exercise "a second
  // snapshot arrives for an already-tracked patient" through the fake at
  // all, so this group mocks the real SDK chain directly instead — same
  // "ignore_for_file: subtype_of_sealed_class" rationale as
  // ems/test/services/patient_upload_service_test.dart's own
  // completeTransportConfirmed group (see that file's header comment for
  // the fuller explanation of why this is the correct call here, not a
  // shortcut).
  group('EmsLocationController with a controlled multi-snapshot Firestore mock', () {
    late _MockFirestore mockFirestore;
    late StreamController<QuerySnapshot<Map<String, dynamic>>> snapshotsController;

    setUp(() {
      mockFirestore = _MockFirestore();
      // Single-subscription (not .broadcast()) — events added before
      // EmsLocationController's own .snapshots().listen(...) call (i.e.
      // before the container's very first read of emsLocationProvider)
      // are buffered and delivered once it subscribes, rather than
      // silently dropped the way a broadcast controller's would be.
      snapshotsController = StreamController<QuerySnapshot<Map<String, dynamic>>>();
      final query = _MockQuery();
      final scopedQuery = _MockQuery();
      when(() => mockFirestore.collectionGroup('location')).thenReturn(query);
      when(
        () => query.where('organizationId', isEqualTo: any(named: 'isEqualTo')),
      ).thenReturn(scopedQuery);
      when(
        () => scopedQuery.where('active', isEqualTo: any(named: 'isEqualTo')),
      ).thenReturn(scopedQuery);
      when(() => scopedQuery.snapshots()).thenAnswer((_) => snapshotsController.stream);
    });

    tearDown(() => snapshotsController.close());

    Future<ProviderContainer> mockContainerFor(UserProfile? profile) async {
      final container = ProviderContainer(
        overrides: [
          firestoreProvider.overrideWithValue(mockFirestore),
          userProfileProvider.overrideWith((ref) => Stream.value(profile)),
        ],
      );
      await container.read(userProfileProvider.future);
      return container;
    }

    test('carries the previous fix forward once a second snapshot arrives for the same patient', () async {
      const profile = UserProfile(role: [UserRole.physician], organizationId: 'org-1');
      final container = await mockContainerFor(profile);
      addTearDown(container.dispose);

      snapshotsController.add(
        _querySnapshot([_locationDoc('patient-1', latitude: 45.0, longitude: -75.0)]),
      );
      await _waitUntil(container, (s) => s.info['patient-1'] != null);

      final state = await _waitForNextEmission(container, () {
        snapshotsController.add(
          _querySnapshot([_locationDoc('patient-1', latitude: 46.0, longitude: -76.0)]),
        );
      });

      final location = state.info['patient-1']!.location!;
      expect(location.latitude, 46.0);
      expect(location.previousLatitude, 45.0);
      expect(location.previousLongitude, -75.0);
    });

    test('a patient missing from a later snapshot (stopped/aged out) keeps its last-known fix, '
        'not removed from state', () async {
      const profile = UserProfile(role: [UserRole.physician], organizationId: 'org-1');
      final container = await mockContainerFor(profile);
      addTearDown(container.dispose);

      snapshotsController.add(
        _querySnapshot([_locationDoc('patient-1', latitude: 45.0, longitude: -75.0)]),
      );
      await _waitUntil(container, (s) => s.info['patient-1'] != null);

      // A later snapshot, e.g. because this patient dropped out of the
      // active==true filter — the doc is genuinely gone from the query's
      // result set, but by design (see the source's own comment)
      // _latest never prunes an entry just because its doc stopped
      // appearing. _waitForNextEmission (not _waitUntil) confirms this
      // *specific* empty snapshot was actually processed, rather than
      // trivially matching on a predicate the first snapshot already
      // satisfied.
      final state = await _waitForNextEmission(container, () {
        snapshotsController.add(_querySnapshot(const []));
      });

      expect(state.info.containsKey('patient-1'), true);
      expect(state.info['patient-1']!.location!.latitude, 45.0);
    });
  });

  group('emsTrackingInfo', () {
    test('a null patientId is always noData, without even reading the provider', () {
      final ref = _MockWidgetRef();
      expect(emsTrackingInfo(ref, null).status, EmsTrackingStatus.noData);
      verifyNever(() => ref.watch(emsLocationProvider));
    });

    test('reports loading before the first snapshot has been received', () {
      final ref = _MockWidgetRef();
      when(() => ref.watch(emsLocationProvider)).thenReturn(const EmsLocationState());

      expect(emsTrackingInfo(ref, 'patient-1').status, EmsTrackingStatus.loading);
    });

    test('reports noData once loaded but this patient has no entry', () {
      final ref = _MockWidgetRef();
      when(() => ref.watch(emsLocationProvider)).thenReturn(const EmsLocationState(hasLoadedOnce: true));

      expect(emsTrackingInfo(ref, 'patient-1').status, EmsTrackingStatus.noData);
    });

    test('passes through this patient\'s known info unchanged', () {
      const info = EmsTrackingInfo(status: EmsTrackingStatus.active);
      final ref = _MockWidgetRef();
      when(
        () => ref.watch(emsLocationProvider),
      ).thenReturn(const EmsLocationState(hasLoadedOnce: true, info: {'patient-1': info}));

      expect(emsTrackingInfo(ref, 'patient-1'), same(info));
    });
  });
}
