import 'package:amdash_core/amdash_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:physician/services/patient_alert_service.dart';

class _MockFirebaseMessaging extends Mock implements FirebaseMessaging {}

class _MockNotificationSettings extends Mock implements NotificationSettings {}

void main() {
  late _MockFirebaseMessaging messaging;
  late FakeFirebaseFirestore firestore;
  late PatientAlertService service;

  setUp(() {
    messaging = _MockFirebaseMessaging();
    firestore = FakeFirebaseFirestore();
    service = PatientAlertService(messaging, UserProfileService(firestore));
  });

  group('enableAlerts', () {
    test('requestPermission throwing is captured in debugLastEnableAlertsError and rethrown, '
        'and mirrored to Firestore', () async {
      final thrown = Exception('service worker registration failed');
      when(() => messaging.requestPermission()).thenThrow(thrown);

      await expectLater(() => service.enableAlerts('user-1', 24), throwsA(thrown));
      expect(debugLastEnableAlertsError, thrown);
      // Mirrored to Firestore too — debugLastEnableAlertsError doesn't
      // exist in a real production build, so this is the only way a real
      // device's failure is ever observable at all (see
      // recordFcmRegistrationError's own doc comment).
      final doc = await firestore.collection('users').doc('user-1').get();
      expect(doc.data()?['lastFcmRegistrationError'], thrown.toString());
      expect(doc.data()?['lastFcmRegistrationErrorAt'], isNotNull);
    });

    test('permission denied -> not granted, never requests a token, records why in Firestore', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.denied);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);

      final result = await service.enableAlerts('user-1', 24);

      expect(result.granted, false);
      verifyNever(() => messaging.getToken(vapidKey: any(named: 'vapidKey')));
      final doc = await firestore.collection('users').doc('user-1').get();
      expect(doc.data()?['lastFcmRegistrationError'], contains('denied'));
    });

    test('permission granted but no token available -> not granted, records why in Firestore', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => null);

      final result = await service.enableAlerts('user-1', 24);

      expect(result.granted, false);
      final doc = await firestore.collection('users').doc('user-1').get();
      expect(doc.data()?['lastFcmRegistrationError'], contains('getToken() returned null'));
    });

    test('permission granted with a token -> writes fcmTokens/newPatientAlertsExpiresAt and reports granted', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => 'fcm-token-1');

      final result = await service.enableAlerts('user-1', 24);

      expect(result.granted, true);
      final doc = await firestore.collection('users').doc('user-1').get();
      final data = doc.data()!;
      expect(data['fcmTokens'], contains('fcm-token-1'));
      expect(data['newPatientAlertsExpiresAt'], isNotNull);
      // On every platform but iOS, _ensureApnsTokenReady is a pure no-op —
      // this is the default test platform (never iOS unless overridden,
      // see the 'waits for a native APNs token on iOS' group below).
      verifyNever(() => messaging.getAPNSToken());
    });

    test('etaAlertThresholdsMinutes defaults to empty when not passed', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => 'fcm-token-1');

      await service.enableAlerts('user-1', 24);

      final doc = await firestore.collection('users').doc('user-1').get();
      expect(doc.data()!['etaAlertThresholdsMinutes'], isEmpty);
    });

    test('writes the given etaAlertThresholdsMinutes when passed', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => 'fcm-token-1');

      await service.enableAlerts('user-1', 24, etaAlertThresholdsMinutes: [60, 15]);

      final doc = await firestore.collection('users').doc('user-1').get();
      expect(doc.data()!['etaAlertThresholdsMinutes'], [60, 15]);
    });
  });

  group('waits for a native APNs token on iOS before requesting one', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('APNs token already available -> registers immediately, no retry delay', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getAPNSToken()).thenAnswer((_) async => 'apns-token');
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => 'fcm-token-1');

      final result = await service.enableAlerts('user-1', 24);

      expect(result.granted, true);
      verify(() => messaging.getAPNSToken()).called(1);
    });

    test('APNs token arrives after a couple of retries -> waits, then registers', () {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => 'fcm-token-1');
      var apnsCallCount = 0;
      when(() => messaging.getAPNSToken()).thenAnswer((_) async {
        apnsCallCount++;
        return apnsCallCount < 3 ? null : 'apns-token';
      });

      // A plain test() has no flutter_test fake-async binding driving the
      // real Future.delayed retry loop — fakeAsync lets this advance
      // exactly as far as the loop's own real delays without waiting out
      // real wall-clock time (same pattern as ems's own
      // battery_watch_service_test.dart / ems_alert_service_test.dart).
      fakeAsync((async) {
        service.enableAlerts('user-1', 24);
        async.elapse(const Duration(seconds: 3));

        expect(apnsCallCount, 3);
      });
    });

    test('APNs token never arrives -> gives up after the max attempts and calls getToken() anyway', () {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getAPNSToken()).thenAnswer((_) async => null);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => 'fcm-token-1');

      fakeAsync((async) {
        service.enableAlerts('user-1', 24);
        async.elapse(const Duration(seconds: 15));

        verify(() => messaging.getAPNSToken()).called(10);
        verify(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).called(1);
      });
    });
  });

  group('disableAlerts', () {
    test('delegates to UserProfileService.disableNewPatientAlerts', () async {
      await firestore.collection('users').doc('user-1').set({'newPatientAlertsExpiresAt': 'placeholder'});

      await service.disableAlerts('user-1');

      final doc = await firestore.collection('users').doc('user-1').get();
      expect(doc.data()!.containsKey('newPatientAlertsExpiresAt'), false);
    });
  });

  group('patientAlertServiceProvider', () {
    test('is wired to firebaseMessagingProvider\'s current instance', () {
      final container = ProviderContainer(
        overrides: [
          firebaseMessagingProvider.overrideWithValue(messaging),
          firestoreProvider.overrideWithValue(firestore),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(patientAlertServiceProvider), isA<PatientAlertService>());
    });
  });
}
