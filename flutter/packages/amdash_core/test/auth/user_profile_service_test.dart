import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UserProfileService (class methods)', () {
    late FakeFirebaseFirestore firestore;
    late UserProfileService service;

    setUp(() {
      firestore = FakeFirebaseFirestore();
      service = UserProfileService(firestore);
    });

    Future<Map<String, Object?>?> readUser(String uid) async {
      final snapshot = await firestore.collection('users').doc(uid).get();
      return snapshot.data();
    }

    test('initializeProfile merge-writes just the email', () async {
      await service.initializeProfile('uid-1', 'a@example.com');
      final data = await readUser('uid-1');
      expect(data?['email'], 'a@example.com');
    });

    test('saveProfile merge-writes firstName/lastName without touching other fields', () async {
      await firestore.collection('users').doc('uid-1').set({'email': 'a@example.com'});
      await service.saveProfile('uid-1', 'Jordan', 'Smith');
      final data = await readUser('uid-1');
      expect(data?['firstName'], 'Jordan');
      expect(data?['lastName'], 'Smith');
      expect(data?['email'], 'a@example.com');
    });

    test('saveWorkLocation merge-writes workLocation', () async {
      await service.saveWorkLocation('uid-1', "St. Michael's Hospital");
      final data = await readUser('uid-1');
      expect(data?['workLocation'], "St. Michael's Hospital");
    });

    test('enableNewPatientAlerts sets the expiry, unions the fcm token, and sets the eta thresholds', () async {
      await firestore.collection('users').doc('uid-1').set({
        'fcmTokens': ['existing-token'],
      });
      final expiresAt = Timestamp.fromDate(DateTime(2026, 12, 31));
      await service.enableNewPatientAlerts('uid-1', expiresAt, 'new-token', [60, 15]);

      final data = await readUser('uid-1');
      expect(data?['newPatientAlertsExpiresAt'], expiresAt);
      expect(data?['fcmTokens'], containsAll(['existing-token', 'new-token']));
      expect(data?['etaAlertThresholdsMinutes'], [60, 15]);
    });

    test('enableNewPatientAlerts overwrites (not unions) a previous eta threshold selection', () async {
      final expiresAt = Timestamp.fromDate(DateTime(2026, 12, 31));
      await firestore.collection('users').doc('uid-1').set({'etaAlertThresholdsMinutes': [60]});
      await service.enableNewPatientAlerts('uid-1', expiresAt, 'new-token', [15, 5]);

      final data = await readUser('uid-1');
      expect(data?['etaAlertThresholdsMinutes'], [15, 5]);
    });

    test('registerFcmToken unions a token without touching newPatientAlertsExpiresAt/'
        'etaAlertThresholdsMinutes', () async {
      final expiresAt = Timestamp.fromDate(DateTime(2026, 12, 31));
      await firestore.collection('users').doc('uid-1').set({
        'fcmTokens': ['existing-token'],
        'newPatientAlertsExpiresAt': expiresAt,
        'etaAlertThresholdsMinutes': [60],
      });
      await service.registerFcmToken('uid-1', 'ems-token');

      final data = await readUser('uid-1');
      expect(data?['fcmTokens'], containsAll(['existing-token', 'ems-token']));
      expect(data?['newPatientAlertsExpiresAt'], expiresAt);
      expect(data?['etaAlertThresholdsMinutes'], [60]);
    });

    test('registerFcmToken merge-creates the doc when none exists yet', () async {
      await service.registerFcmToken('uid-2', 'ems-token');
      final data = await readUser('uid-2');
      expect(data?['fcmTokens'], ['ems-token']);
    });

    test('disableNewPatientAlerts deletes the expiry field, leaving fcmTokens alone', () async {
      final expiresAt = Timestamp.fromDate(DateTime(2026, 12, 31));
      await firestore.collection('users').doc('uid-1').set({
        'newPatientAlertsExpiresAt': expiresAt,
        'fcmTokens': ['token-1'],
      });
      await service.disableNewPatientAlerts('uid-1');

      final data = await readUser('uid-1');
      expect(data?.containsKey('newPatientAlertsExpiresAt'), false);
      expect(data?['fcmTokens'], ['token-1']);
    });
  });

  group('userProfileServiceProvider', () {
    test('is wired to firestoreProvider\'s current instance', () {
      final firestore = FakeFirebaseFirestore();
      final container = ProviderContainer(
        overrides: [firestoreProvider.overrideWithValue(firestore)],
      );
      addTearDown(container.dispose);

      final service = container.read(userProfileServiceProvider);
      expect(service, isA<UserProfileService>());
    });
  });

  group('userProfileProvider', () {
    late FakeFirebaseFirestore firestore;

    setUp(() {
      firestore = FakeFirebaseFirestore();
    });

    Future<ProviderContainer> containerFor(User? user) async {
      final container = ProviderContainer(
        overrides: [
          firestoreProvider.overrideWithValue(firestore),
          authStateProvider.overrideWith((ref) => Stream.value(user)),
        ],
      );
      await container.read(authStateProvider.future);
      return container;
    }

    test('does not resolve while authStateProvider is still loading', () async {
      final container = ProviderContainer(
        overrides: [
          firestoreProvider.overrideWithValue(firestore),
          // Never emits/completes — authState.isLoading stays true for the
          // lifetime of this test, same technique app_guards_test.dart uses.
          authStateProvider.overrideWith((ref) => StreamController<User?>().stream),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(userProfileProvider), const AsyncValue<UserProfile?>.loading());
    });

    test('yields null once signed-out is confirmed (not just while loading)', () async {
      final container = await containerFor(null);
      addTearDown(container.dispose);

      final profile = await container.read(userProfileProvider.future);
      expect(profile, isNull);
    });

    test('yields null if the signed-in user has no users/{uid} doc yet', () async {
      final container = await containerFor(MockUser(uid: 'uid-1'));
      addTearDown(container.dispose);

      final profile = await container.read(userProfileProvider.future);
      expect(profile, isNull);
    });

    test('maps the signed-in user\'s document once it exists', () async {
      await firestore.collection('users').doc('uid-1').set({
        'firstName': 'Jordan',
        'lastName': 'Smith',
        'role': ['physician'],
      });
      final container = await containerFor(MockUser(uid: 'uid-1'));
      addTearDown(container.dispose);

      final profile = await container.read(userProfileProvider.future);
      expect(profile?.firstName, 'Jordan');
      expect(profile?.role, [UserRole.physician]);
    });

    test('re-subscribing to a different signed-in user reads that user\'s own doc', () async {
      await firestore.collection('users').doc('uid-1').set({'firstName': 'Jordan'});
      await firestore.collection('users').doc('uid-2').set({'firstName': 'Alex'});

      final containerA = await containerFor(MockUser(uid: 'uid-1'));
      addTearDown(containerA.dispose);
      final profileA = await containerA.read(userProfileProvider.future);
      expect(profileA?.firstName, 'Jordan');

      final containerB = await containerFor(MockUser(uid: 'uid-2'));
      addTearDown(containerB.dispose);
      final profileB = await containerB.read(userProfileProvider.future);
      expect(profileB?.firstName, 'Alex');
    });
  });
}
