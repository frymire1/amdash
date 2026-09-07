import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:ems/services/ems_alert_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockFirebaseMessaging extends Mock implements FirebaseMessaging {}

class _MockNotificationSettings extends Mock implements NotificationSettings {}

void main() {
  late _MockFirebaseMessaging messaging;
  late FakeFirebaseFirestore firestore;
  late EmsAlertService service;

  setUp(() {
    messaging = _MockFirebaseMessaging();
    firestore = FakeFirebaseFirestore();
    service = EmsAlertService(messaging, UserProfileService(firestore));
  });

  group('registerForConnectivityAlerts', () {
    test('requestPermission throwing is captured in '
        'debugLastRegisterForConnectivityAlertsError and swallowed (not rethrown), and mirrored '
        'to Firestore', () async {
      final thrown = Exception('service worker registration failed');
      when(() => messaging.requestPermission()).thenThrow(thrown);

      // Unlike PatientAlertService.enableAlerts, this must not throw — see
      // ems_alert_service.dart's own doc comment on why a failure here is
      // deliberately swallowed.
      await service.registerForConnectivityAlerts('ems-1');

      expect(debugLastRegisterForConnectivityAlertsError, thrown);
      // Mirrored to Firestore too — debugLastRegisterForConnectivityAlertsError
      // doesn't exist in a real production build, so this is the only way
      // a real device's failure is ever observable at all (see
      // recordFcmRegistrationError's own doc comment).
      final doc = await firestore.collection('users').doc('ems-1').get();
      expect(doc.data()?['lastFcmRegistrationError'], thrown.toString());
      expect(doc.data()?['lastFcmRegistrationErrorAt'], isNotNull);
    });

    test('writes an "attempt started" marker before requestPermission() even resolves, so a '
        'hung/never-resolving native call is still visible in Firestore', () async {
      final settingsCompleter = Completer<NotificationSettings>();
      when(() => messaging.requestPermission()).thenAnswer((_) => settingsCompleter.future);

      final future = service.registerForConnectivityAlerts('ems-1');
      // Lets the marker write (itself async, but not gated on
      // requestPermission() resolving) actually land, without ever
      // resolving requestPermission() at all — proving this doesn't wait
      // on it.
      await pumpEventQueue();

      final doc = await firestore.collection('users').doc('ems-1').get();
      expect(doc.data()?['lastFcmRegistrationError'], contains('has not yet reached an outcome'));

      // Let the still-in-flight call actually finish so it doesn't leak an
      // unresolved Future into a later test.
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.denied);
      settingsCompleter.complete(settings);
      await future;
    });

    test('debugLastRegisterForConnectivityAlertsFinished is false while in flight, '
        'true once settled', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => 'ems-fcm-token');

      final future = service.registerForConnectivityAlerts('ems-1');
      expect(debugLastRegisterForConnectivityAlertsFinished, false);

      await future;
      expect(debugLastRegisterForConnectivityAlertsFinished, true);
    });

    test('permission denied -> never requests a token, records why in Firestore', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.denied);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);

      await service.registerForConnectivityAlerts('ems-1');

      verifyNever(() => messaging.getToken(vapidKey: any(named: 'vapidKey')));
      final doc = await firestore.collection('users').doc('ems-1').get();
      expect(doc.data()?['fcmTokens'], isNull);
      expect(doc.data()?['lastFcmRegistrationError'], contains('denied'));
    });

    test('permission granted but no token available -> records why, writes no token', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => null);

      await service.registerForConnectivityAlerts('ems-1');

      final doc = await firestore.collection('users').doc('ems-1').get();
      expect(doc.data()?['fcmTokens'], isNull);
      expect(doc.data()?['lastFcmRegistrationError'], contains('getToken() returned null'));
    });

    test('permission granted with a token -> registers it via fcmTokens, without an expiry or '
        'threshold fields', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => 'ems-fcm-token');

      await service.registerForConnectivityAlerts('ems-1');

      final doc = await firestore.collection('users').doc('ems-1').get();
      final data = doc.data()!;
      expect(data['fcmTokens'], contains('ems-fcm-token'));
      expect(data.containsKey('newPatientAlertsExpiresAt'), false);
      expect(data.containsKey('etaAlertThresholdsMinutes'), false);
      // On every platform but iOS, _ensureApnsTokenReady is a pure no-op —
      // this is the default test platform (never iOS unless overridden,
      // see the 'waits for a native APNs token on iOS' group below), so
      // this proves the gate actually skips the call rather than it just
      // happening to return non-null.
      verifyNever(() => messaging.getAPNSToken());
    });

    test('a Firestore write failure is captured, not rethrown', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => 'ems-fcm-token');
      final thrown = Exception('offline');
      final failingUserProfileService = _ThrowingUserProfileService(thrown);
      final failingService = EmsAlertService(messaging, failingUserProfileService);

      await failingService.registerForConnectivityAlerts('ems-1');

      expect(debugLastRegisterForConnectivityAlertsError, thrown);
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
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => 'ems-fcm-token');

      await service.registerForConnectivityAlerts('ems-1');

      verify(() => messaging.getAPNSToken()).called(1);
      final doc = await firestore.collection('users').doc('ems-1').get();
      expect(doc.data()!['fcmTokens'], contains('ems-fcm-token'));
    });

    test('APNs token arrives after a couple of retries -> waits, then registers', () {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => 'ems-fcm-token');
      var apnsCallCount = 0;
      when(() => messaging.getAPNSToken()).thenAnswer((_) async {
        apnsCallCount++;
        return apnsCallCount < 3 ? null : 'apns-token';
      });

      // A plain test() has no flutter_test fake-async binding driving the
      // real Future.delayed retry loop — fakeAsync lets this advance
      // exactly as far as the loop's own real delays without waiting out
      // real wall-clock time (same pattern as battery_watch_service_test.dart).
      fakeAsync((async) {
        service.registerForConnectivityAlerts('ems-1');
        async.elapse(const Duration(seconds: 3));

        expect(apnsCallCount, 3);
      });
    });

    test('APNs token never arrives -> gives up after the max attempts and calls getToken() anyway', () {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getAPNSToken()).thenAnswer((_) async => null);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => 'ems-fcm-token');

      fakeAsync((async) {
        service.registerForConnectivityAlerts('ems-1');
        async.elapse(const Duration(seconds: 15));

        verify(() => messaging.getAPNSToken()).called(10);
        verify(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).called(1);
      });
    });
  });

  group('emsAlertServiceProvider', () {
    test('is wired to firebaseMessagingProvider\'s current instance', () {
      final container = ProviderContainer(
        overrides: [
          firebaseMessagingProvider.overrideWithValue(messaging),
          firestoreProvider.overrideWithValue(firestore),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(emsAlertServiceProvider), isA<EmsAlertService>());
    });
  });
}

// A real UserProfileService(firestore) can't be made to throw from
// registerFcmToken without a genuinely broken/offline FakeFirebaseFirestore
// (not something that package exposes a seam for) — overriding just this
// one method is simpler than reaching for a heavier Firestore mock just
// for this one failure-path test.
class _ThrowingUserProfileService extends UserProfileService {
  _ThrowingUserProfileService(this._error) : super(FakeFirebaseFirestore());
  final Object _error;

  @override
  Future<void> registerFcmToken(String uid, String fcmToken) => Future.error(_error);
}
