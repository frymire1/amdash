// Same "mock the real SDK chain directly" rationale as
// ems_location_service_test.dart's own identical ignore_for_file comment —
// fake_cloud_firestore's plain (non-collection-group) queries actually DO
// support live re-snapshotting on document updates, so most of this file
// uses the fake directly; only the "carries the previous... no, doesn't
// carry a previous fix forward" cross-snapshot case needs a controlled
// mock to push two distinct snapshots deterministically.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:physician/services/ambulance_location_service.dart';

class _MockFirestore extends Mock implements FirebaseFirestore {}

class _MockCollectionReference extends Mock implements CollectionReference<Map<String, dynamic>> {}

class _MockQuery extends Mock implements Query<Map<String, dynamic>> {}

class _MockQuerySnapshot extends Mock implements QuerySnapshot<Map<String, dynamic>> {}

class _MockQueryDocSnapshot extends Mock implements QueryDocumentSnapshot<Map<String, dynamic>> {}

QueryDocumentSnapshot<Map<String, dynamic>> _ambulanceDoc(
  String ambulanceId, {
  required double latitude,
  required double longitude,
  bool isTransporting = false,
  Timestamp? updatedAt,
  String phoneNumber = '',
}) {
  final doc = _MockQueryDocSnapshot();
  when(() => doc.data()).thenReturn({
    'organizationId': 'org-1',
    'ambulanceId': ambulanceId,
    'latitude': latitude,
    'longitude': longitude,
    'isTransporting': isTransporting,
    'updatedAt': updatedAt ?? Timestamp.now(),
    'phoneNumber': phoneNumber,
  });
  return doc;
}

QuerySnapshot<Map<String, dynamic>> _querySnapshot(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
  final snapshot = _MockQuerySnapshot();
  when(() => snapshot.docs).thenReturn(docs);
  return snapshot;
}

// AmbulanceLocationController is a Notifier, not a Stream/FutureProvider —
// same _waitUntil/_waitForNextEmission shape as
// ems_location_service_test.dart's own identical helpers.
Future<AmbulanceLocationState> _waitUntil(
  ProviderContainer container,
  bool Function(AmbulanceLocationState) predicate,
) async {
  final current = container.read(ambulanceLocationProvider);
  if (predicate(current)) return current;

  final completer = Completer<AmbulanceLocationState>();
  late final ProviderSubscription<AmbulanceLocationState> sub;
  sub = container.listen(ambulanceLocationProvider, (previous, next) {
    if (predicate(next) && !completer.isCompleted) {
      completer.complete(next);
      sub.close();
    }
  });
  return completer.future;
}

Future<AmbulanceLocationState> _waitForNextEmission(ProviderContainer container, void Function() trigger) {
  final completer = Completer<AmbulanceLocationState>();
  late final ProviderSubscription<AmbulanceLocationState> sub;
  sub = container.listen(ambulanceLocationProvider, (previous, next) {
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

  Future<ProviderContainer> containerFor(Organization? organization) async {
    final container = ProviderContainer(
      overrides: [
        firestoreProvider.overrideWithValue(firestore),
        ownOrganizationProvider.overrideWith((ref) => Stream.value(organization)),
      ],
    );
    // build() itself reads ownOrganizationProvider synchronously (same
    // "needs it already settled" reasoning as EmsLocationController's own
    // test setup) — settle it before returning.
    await container.read(ownOrganizationProvider.future);
    return container;
  }

  group('AmbulanceLocationController', () {
    test('no organization -> hasLoadedOnce true immediately, no query ever issued', () async {
      final container = await containerFor(null);
      addTearDown(container.dispose);

      final state = await _waitUntil(container, (s) => s.hasLoadedOnce);
      expect(state.info, isEmpty);
    });

    test("an organization that hasn't opted into enableMultipleAmbulanceView is treated the same as no org", () async {
      final container = await containerFor(
        const Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: false),
      );
      addTearDown(container.dispose);

      final state = await _waitUntil(container, (s) => s.hasLoadedOnce);
      expect(state.info, isEmpty);
    });

    test('maps a fresh location fix to AmbulanceStatus.active', () async {
      await firestore.collection('ambulanceLocations').doc('doc-1').set({
        'organizationId': 'org-1',
        'ambulanceId': 'Unit 5',
        'latitude': 45.4,
        'longitude': -75.7,
        'isTransporting': true,
        'updatedAt': Timestamp.now(),
        'phoneNumber': '555-0123',
      });

      final container = await containerFor(
        const Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true),
      );
      addTearDown(container.dispose);

      final state = await _waitUntil(container, (s) => s.hasLoadedOnce);
      final info = state.info['Unit 5']!;
      expect(info.status, AmbulanceStatus.active);
      expect(info.location.latitude, 45.4);
      expect(info.location.longitude, -75.7);
      expect(info.location.isTransporting, true);
      expect(info.location.phoneNumber, '555-0123');
    });

    test('a doc written before phoneNumber existed falls back to an empty string, not a crash', () async {
      await firestore.collection('ambulanceLocations').doc('doc-1').set({
        'organizationId': 'org-1',
        'ambulanceId': 'Unit 5',
        'latitude': 45.4,
        'longitude': -75.7,
        'isTransporting': true,
        'updatedAt': Timestamp.now(),
        // No 'phoneNumber' key at all.
      });

      final container = await containerFor(
        const Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true),
      );
      addTearDown(container.dispose);

      final state = await _waitUntil(container, (s) => s.hasLoadedOnce);
      expect(state.info['Unit 5']!.location.phoneNumber, '');
    });

    test('a fix already older than the staleness threshold maps to AmbulanceStatus.stale', () async {
      final staleTimestamp = Timestamp.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch - ambulanceStaleAfterMs - 5000,
      );
      await firestore.collection('ambulanceLocations').doc('doc-1').set({
        'organizationId': 'org-1',
        'ambulanceId': 'Unit 5',
        'latitude': 45.4,
        'longitude': -75.7,
        'isTransporting': false,
        'updatedAt': staleTimestamp,
      });

      final container = await containerFor(
        const Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true),
      );
      addTearDown(container.dispose);

      final state = await _waitUntil(container, (s) => s.hasLoadedOnce);
      expect(state.info['Unit 5']!.status, AmbulanceStatus.stale);
    });

    test('only matches this organizationId', () async {
      await firestore.collection('ambulanceLocations').doc('doc-1').set({
        'organizationId': 'org-1',
        'ambulanceId': 'Unit 5',
        'latitude': 45.4,
        'longitude': -75.7,
        'isTransporting': false,
        'updatedAt': Timestamp.now(),
      });
      await firestore.collection('ambulanceLocations').doc('doc-2').set({
        'organizationId': 'org-2',
        'ambulanceId': 'Unit 9',
        'latitude': 46.0,
        'longitude': -76.0,
        'isTransporting': false,
        'updatedAt': Timestamp.now(),
      });

      final container = await containerFor(
        const Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true),
      );
      addTearDown(container.dispose);

      final state = await _waitUntil(container, (s) => s.hasLoadedOnce);
      expect(state.info.containsKey('Unit 5'), true);
      expect(state.info.containsKey('Unit 9'), false);
    });

    test('re-subscribes to the newly-scoped query when ownOrganizationProvider emits a genuinely later '
        "change (not just build()'s own initial synchronous read)", () async {
      await firestore.collection('ambulanceLocations').doc('doc-1').set({
        'organizationId': 'org-1',
        'ambulanceId': 'Unit 5',
        'latitude': 45.4,
        'longitude': -75.7,
        'isTransporting': false,
        'updatedAt': Timestamp.now(),
      });
      await firestore.collection('ambulanceLocations').doc('doc-2').set({
        'organizationId': 'org-2',
        'ambulanceId': 'Unit 9',
        'latitude': 46.0,
        'longitude': -76.0,
        'isTransporting': false,
        'updatedAt': Timestamp.now(),
      });

      final orgController = StreamController<Organization?>();
      addTearDown(orgController.close);
      final container = ProviderContainer(
        overrides: [
          firestoreProvider.overrideWithValue(firestore),
          ownOrganizationProvider.overrideWith((ref) => orgController.stream),
        ],
      );
      addTearDown(container.dispose);

      orgController.add(const Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true));
      await container.read(ownOrganizationProvider.future);

      final orgOneState = await _waitUntil(container, (s) => s.hasLoadedOnce);
      expect(orgOneState.info.containsKey('Unit 5'), true);
      expect(orgOneState.info.containsKey('Unit 9'), false);

      orgController.add(const Organization(id: 'org-2', name: 'Org', enableMultipleAmbulanceView: true));
      final orgTwoState = await _waitUntil(container, (s) => s.info.containsKey('Unit 9'));
      expect(orgTwoState.info.containsKey('Unit 9'), true);
      // _latest is reset on every resubscribe — org-1's ambulance doesn't
      // carry over into the new org's state.
      expect(orgTwoState.info.containsKey('Unit 5'), false);
    });

    test('the org flag turning off mid-session tears down the subscription (no more query results)', () async {
      await firestore.collection('ambulanceLocations').doc('doc-1').set({
        'organizationId': 'org-1',
        'ambulanceId': 'Unit 5',
        'latitude': 45.4,
        'longitude': -75.7,
        'isTransporting': false,
        'updatedAt': Timestamp.now(),
      });

      final orgController = StreamController<Organization?>();
      addTearDown(orgController.close);
      final container = ProviderContainer(
        overrides: [
          firestoreProvider.overrideWithValue(firestore),
          ownOrganizationProvider.overrideWith((ref) => orgController.stream),
        ],
      );
      addTearDown(container.dispose);

      orgController.add(const Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true));
      await container.read(ownOrganizationProvider.future);
      await _waitUntil(container, (s) => s.info.containsKey('Unit 5'));

      final state = await _waitForNextEmission(container, () {
        orgController.add(const Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: false));
      });

      expect(state.hasLoadedOnce, true);
      expect(state.info, isEmpty);
    });
  });

  // Same rationale as EmsLocationController's own "controlled multi-
  // snapshot Firestore mock" group — needed to push two distinct
  // snapshots for the same ambulance deterministically, which
  // fake_cloud_firestore's own live query doesn't reliably support for
  // this exact cross-snapshot case.
  group('AmbulanceLocationController with a controlled multi-snapshot Firestore mock', () {
    late _MockFirestore mockFirestore;
    late StreamController<QuerySnapshot<Map<String, dynamic>>> snapshotsController;

    setUp(() {
      mockFirestore = _MockFirestore();
      snapshotsController = StreamController<QuerySnapshot<Map<String, dynamic>>>();
      final collection = _MockCollectionReference();
      final scopedQuery = _MockQuery();
      when(() => mockFirestore.collection('ambulanceLocations')).thenReturn(collection);
      when(() => collection.where('organizationId', isEqualTo: any(named: 'isEqualTo'))).thenReturn(scopedQuery);
      when(() => scopedQuery.snapshots()).thenAnswer((_) => snapshotsController.stream);
    });

    tearDown(() => snapshotsController.close());

    Future<ProviderContainer> mockContainerFor(Organization? organization) async {
      final container = ProviderContainer(
        overrides: [
          firestoreProvider.overrideWithValue(mockFirestore),
          ownOrganizationProvider.overrideWith((ref) => Stream.value(organization)),
        ],
      );
      await container.read(ownOrganizationProvider.future);
      return container;
    }

    test('a later fix for the same ambulance replaces the earlier one, with no previous-fix carried forward', () async {
      const org = Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true);
      final container = await mockContainerFor(org);
      addTearDown(container.dispose);

      snapshotsController.add(_querySnapshot([_ambulanceDoc('Unit 5', latitude: 45.0, longitude: -75.0)]));
      await _waitUntil(container, (s) => s.info['Unit 5'] != null);

      final state = await _waitForNextEmission(container, () {
        snapshotsController.add(_querySnapshot([_ambulanceDoc('Unit 5', latitude: 46.0, longitude: -76.0)]));
      });

      final location = state.info['Unit 5']!.location;
      expect(location.latitude, 46.0);
      expect(location.longitude, -76.0);
    });

    test('an ambulance missing from a later snapshot keeps its last-known fix, not removed from state', () async {
      const org = Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true);
      final container = await mockContainerFor(org);
      addTearDown(container.dispose);

      snapshotsController.add(_querySnapshot([_ambulanceDoc('Unit 5', latitude: 45.0, longitude: -75.0)]));
      await _waitUntil(container, (s) => s.info['Unit 5'] != null);

      final state = await _waitForNextEmission(container, () {
        snapshotsController.add(_querySnapshot(const []));
      });

      expect(state.info.containsKey('Unit 5'), true);
      expect(state.info['Unit 5']!.location.latitude, 45.0);
    });

    test('a doc missing a required field is skipped rather than crashing the whole snapshot', () async {
      const org = Organization(id: 'org-1', name: 'Org', enableMultipleAmbulanceView: true);
      final container = await mockContainerFor(org);
      addTearDown(container.dispose);

      final incompleteDoc = _MockQueryDocSnapshot();
      when(() => incompleteDoc.data()).thenReturn({
        'organizationId': 'org-1',
        'ambulanceId': 'Unit 5',
        // latitude/longitude/updatedAt all missing.
      });

      final state = await _waitForNextEmission(container, () {
        snapshotsController.add(_querySnapshot([incompleteDoc]));
      });

      expect(state.hasLoadedOnce, true);
      expect(state.info, isEmpty);
    });
  });
}
