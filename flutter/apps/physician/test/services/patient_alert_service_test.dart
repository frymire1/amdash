import 'package:amdash_core/amdash_core.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
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
    test('permission denied -> not granted, never requests a token', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.denied);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);

      final result = await service.enableAlerts('user-1', 24);

      expect(result.granted, false);
      verifyNever(() => messaging.getToken(vapidKey: any(named: 'vapidKey')));
    });

    test('permission granted but no token available -> not granted', () async {
      final settings = _MockNotificationSettings();
      when(() => settings.authorizationStatus).thenReturn(AuthorizationStatus.authorized);
      when(() => messaging.requestPermission()).thenAnswer((_) async => settings);
      when(() => messaging.getToken(vapidKey: any(named: 'vapidKey'))).thenAnswer((_) async => null);

      final result = await service.enableAlerts('user-1', 24);

      expect(result.granted, false);
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
