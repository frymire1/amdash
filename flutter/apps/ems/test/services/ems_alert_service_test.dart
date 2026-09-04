import 'package:amdash_core/amdash_core.dart';
import 'package:ems/services/ems_alert_service.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
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
        'debugLastRegisterForConnectivityAlertsError and swallowed (not rethrown)', () async {
      final thrown = Exception('service worker registration failed');
      when(() => messaging.requestPermission()).thenThrow(thrown);

      // Unlike PatientAlertService.enableAlerts, this must not throw — see
      // ems_alert_service.dart's own doc comment on why a failure here is
      // deliberately swallowed.
      await service.registerForConnectivityAlerts('ems-1');

      expect(debugLastRegisterForConnectivityAlertsError, thrown);
      final doc = await firestore.collection('users').doc('ems-1').get();
      expect(doc.exists, false);
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

    test('permission denied -> never requests a token, never writes anything', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.denied);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);

      await service.registerForConnectivityAlerts('ems-1');

      verifyNever(() => messaging.getToken(vapidKey: any(named: 'vapidKey')));
      final doc = await firestore.collection('users').doc('ems-1').get();
      expect(doc.exists, false);
    });

    test('permission granted but no token available -> writes nothing', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => null);

      await service.registerForConnectivityAlerts('ems-1');

      final doc = await firestore.collection('users').doc('ems-1').get();
      expect(doc.exists, false);
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
