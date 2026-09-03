import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:physician/screens/user_settings_screen.dart';
import 'package:physician/services/patient_alert_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/pump_app.dart';

class _MockUser extends Mock implements User {}

class _MockAuthService extends Mock implements AuthService {}

class _MockUserProfileService extends Mock implements UserProfileService {}

class _MockMfaService extends Mock implements MfaService {}

class _MockPatientAlertService extends Mock implements PatientAlertService {}

const _hospitals = ['Ottawa General', 'Ottawa Civic', 'Kingston General'];

void main() {
  late _MockUser user;
  late _MockAuthService authService;
  late _MockUserProfileService userProfileService;
  late _MockMfaService mfaService;
  late _MockPatientAlertService patientAlertService;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    user = _MockUser();
    when(() => user.uid).thenReturn('uid-1');
    when(() => user.email).thenReturn('jordan@example.com');
    authService = _MockAuthService();
    when(() => authService.currentUser).thenReturn(user);
    userProfileService = _MockUserProfileService();
    mfaService = _MockMfaService();
    patientAlertService = _MockPatientAlertService();
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    UserProfile profile = const UserProfile(firstName: 'Jordan', lastName: 'Lee', workLocation: 'Ottawa Civic'),
  }) {
    return pumpApp(
      tester,
      const SizedBox(),
      overrides: [
        authStateProvider.overrideWith((ref) => Stream.value(user)),
        userProfileProvider.overrideWith((ref) => Stream.value(profile)),
        userProfileServiceProvider.overrideWithValue(userProfileService),
        authServiceProvider.overrideWithValue(authService),
        mfaServiceProvider.overrideWithValue(mfaService),
        mfaEnrolledFactorsProvider.overrideWith((ref) async => const []),
        hospitalNamesProvider.overrideWithValue(_hospitals),
        patientAlertServiceProvider.overrideWithValue(patientAlertService),
      ],
      // Not const — a compile-time-const construction never registers a
      // runtime hit on the constructor's own declaration line.
      routes: {'/settings': (_) => UserSettingsScreen()},
      initialLocation: '/settings',
    );
  }

  testWidgets('prefills name and hospital fields from the live profile', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Jordan'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Lee'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Ottawa Civic'), findsOneWidget);
  });

  testWidgets('no signed-in user renders nothing', (tester) async {
    await pumpApp(
      tester,
      const SizedBox(),
      overrides: [
        authStateProvider.overrideWith((ref) => Stream.value(null)),
        userProfileProvider.overrideWith((ref) => Stream.value(null)),
        userProfileServiceProvider.overrideWithValue(userProfileService),
        authServiceProvider.overrideWithValue(authService),
        mfaServiceProvider.overrideWithValue(mfaService),
        mfaEnrolledFactorsProvider.overrideWith((ref) async => const []),
        hospitalNamesProvider.overrideWithValue(_hospitals),
        patientAlertServiceProvider.overrideWithValue(patientAlertService),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('User Settings'), findsNothing);
  });

  testWidgets('tapping back with nothing to pop navigates home', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byKey(pumpAppHomeKey), findsOneWidget);
  });

  group('profile', () {
    testWidgets('submitting with an empty first name is a no-op', (tester) async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Jordan'), '');
      await tester.tap(find.text('Save').first);
      await tester.pumpAndSettle();

      verifyNever(() => userProfileService.saveProfile(any(), any(), any()));
    });

    testWidgets('saving successfully shows the success line', (tester) async {
      when(() => userProfileService.saveProfile(any(), any(), any())).thenAnswer((_) async {});

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Lee'), 'Nguyen');
      await tester.tap(find.text('Save').first);
      await tester.pumpAndSettle();

      verify(() => userProfileService.saveProfile('uid-1', 'Jordan', 'Nguyen')).called(1);
      expect(find.text('Saved.'), findsOneWidget);
    });

    testWidgets('saving that times out shows the connection-specific message', (tester) async {
      when(() => userProfileService.saveProfile(any(), any(), any())).thenAnswer((_) => Completer<void>().future);

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save').first);
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      await tester.pump();

      expect(find.text('This is taking longer than expected. Check your connection and try again.'), findsOneWidget);
    });

    testWidgets('saving that fails generically shows the generic error', (tester) async {
      when(() => userProfileService.saveProfile(any(), any(), any())).thenThrow(Exception('permission-denied'));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save').first);
      await tester.pumpAndSettle();

      expect(find.text('Failed to save your details. Please try again.'), findsOneWidget);
    });
  });

  group('hospital', () {
    testWidgets('typing an unmatched hospital and tapping outside shows the validation error', (tester) async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Ottawa Civic'), 'Not A Real Hospital');
      await tester.pump();
      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();

      expect(find.text('Select a hospital from the list.'), findsOneWidget);
      verifyNever(() => userProfileService.saveWorkLocation(any(), any()));
    });

    testWidgets('saving an unmatched hospital is a no-op that still marks it touched', (tester) async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Ottawa Civic'), 'Nowhere');
      await tester.pump();
      await tester.ensureVisible(find.text('Save').at(1));
      await tester.tap(find.text('Save').at(1));
      await tester.pumpAndSettle();

      expect(find.text('Select a hospital from the list.'), findsOneWidget);
      verifyNever(() => userProfileService.saveWorkLocation(any(), any()));
    });

    testWidgets('selecting an option from the autocomplete list fills the field and allows saving', (tester) async {
      when(() => userProfileService.saveWorkLocation(any(), any())).thenAnswer((_) async {});

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Ottawa Civic'), 'kingston');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kingston General'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Save').at(1));
      await tester.tap(find.text('Save').at(1));
      await tester.pumpAndSettle();

      verify(() => userProfileService.saveWorkLocation('uid-1', 'Kingston General')).called(1);
    });

    testWidgets('saving a matching hospital succeeds', (tester) async {
      when(() => userProfileService.saveWorkLocation(any(), any())).thenAnswer((_) async {});

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Ottawa Civic'), 'Kingston General');
      await tester.pump();
      await tester.ensureVisible(find.text('Save').at(1));
      await tester.tap(find.text('Save').at(1));
      await tester.pumpAndSettle();

      verify(() => userProfileService.saveWorkLocation('uid-1', 'Kingston General')).called(1);
    });

    testWidgets('saving that times out shows the connection-specific message', (tester) async {
      when(() => userProfileService.saveWorkLocation(any(), any())).thenAnswer((_) => Completer<void>().future);

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Save').at(1));
      await tester.tap(find.text('Save').at(1));
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      await tester.pump();

      expect(find.text('This is taking longer than expected. Check your connection and try again.'), findsOneWidget);
    });

    testWidgets('saving that fails generically shows the generic error', (tester) async {
      when(() => userProfileService.saveWorkLocation(any(), any())).thenThrow(Exception('permission-denied'));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Save').at(1));
      await tester.ensureVisible(find.text('Save').at(1));
      await tester.tap(find.text('Save').at(1));
      await tester.pumpAndSettle();

      expect(find.text('Failed to save your hospital. Please try again.'), findsOneWidget);
    });
  });

  group('new patient alerts', () {
    testWidgets('no active window: shows "Alerts are currently off"', (tester) async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('Alerts are currently off.'), findsOneWidget);
    });

    testWidgets('an active window: shows the armed-until message', (tester) async {
      await pumpScreen(
        tester,
        profile: UserProfile(
          firstName: 'Jordan',
          lastName: 'Lee',
          workLocation: 'Ottawa Civic',
          newPatientAlertsExpiresAt: Timestamp.fromDate(DateTime.now().add(const Duration(hours: 2))),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Alerts armed until'), findsOneWidget);
    });

    testWidgets('an expired window: still shows "Alerts are currently off"', (tester) async {
      await pumpScreen(
        tester,
        profile: UserProfile(
          firstName: 'Jordan',
          lastName: 'Lee',
          workLocation: 'Ottawa Civic',
          newPatientAlertsExpiresAt: Timestamp.fromDate(DateTime.now().subtract(const Duration(hours: 2))),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alerts are currently off.'), findsOneWidget);
    });

    testWidgets('picking a duration other than the default pluralizes "hours"', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('4 hours'));
      await tester.tap(find.text('4 hours'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 hour').last);
      await tester.pumpAndSettle();

      expect(find.text('1 hour'), findsOneWidget);
    });

    testWidgets('enabling successfully leaves no blocked message', (tester) async {
      when(
        () => patientAlertService.enableAlerts('uid-1', 4, etaAlertThresholdsMinutes: const []),
      ).thenAnswer((_) async => const EnableAlertsResult(granted: true));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Enable'));
      await tester.tap(find.text('Enable'));
      await tester.pumpAndSettle();

      verify(() => patientAlertService.enableAlerts('uid-1', 4, etaAlertThresholdsMinutes: const [])).called(1);
      expect(find.textContaining('blocked'), findsNothing);
    });

    testWidgets('enabling when browser notifications are blocked shows the blocked message', (tester) async {
      when(
        () => patientAlertService.enableAlerts('uid-1', 4, etaAlertThresholdsMinutes: const []),
      ).thenAnswer((_) async => const EnableAlertsResult(granted: false));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Enable'));
      await tester.tap(find.text('Enable'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining("Notifications are blocked in your browser"),
        findsOneWidget,
      );
    });

    testWidgets('enabling that throws shows the generic failure message', (tester) async {
      when(
        () => patientAlertService.enableAlerts('uid-1', 4, etaAlertThresholdsMinutes: const []),
      ).thenThrow(Exception('boom'));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Enable'));
      await tester.tap(find.text('Enable'));
      await tester.pumpAndSettle();

      expect(find.text('Failed to enable alerts. Please try again.'), findsOneWidget);
    });

    testWidgets('checking a threshold box and enabling passes the selected thresholds', (tester) async {
      when(
        () => patientAlertService.enableAlerts('uid-1', 4, etaAlertThresholdsMinutes: const [60, 15]),
      ).thenAnswer((_) async => const EnableAlertsResult(granted: true));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('eta_threshold_60')));
      await tester.tap(find.byKey(const Key('eta_threshold_60')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('eta_threshold_15')));
      await tester.tap(find.byKey(const Key('eta_threshold_15')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Enable'));
      await tester.tap(find.text('Enable'));
      await tester.pumpAndSettle();

      verify(() => patientAlertService.enableAlerts('uid-1', 4, etaAlertThresholdsMinutes: const [60, 15])).called(1);
    });

    testWidgets('unchecking a previously-checked threshold box removes it', (tester) async {
      when(
        () => patientAlertService.enableAlerts('uid-1', 4, etaAlertThresholdsMinutes: const []),
      ).thenAnswer((_) async => const EnableAlertsResult(granted: true));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      final box = find.byKey(const Key('eta_threshold_5'));
      await tester.ensureVisible(box);
      await tester.tap(box); // check
      await tester.pumpAndSettle();
      await tester.tap(box); // uncheck
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Enable'));
      await tester.tap(find.text('Enable'));
      await tester.pumpAndSettle();

      verify(() => patientAlertService.enableAlerts('uid-1', 4, etaAlertThresholdsMinutes: const [])).called(1);
    });

    testWidgets('prefills previously-saved threshold selections as checked', (tester) async {
      await pumpScreen(
        tester,
        profile: UserProfile(
          firstName: 'Jordan',
          lastName: 'Lee',
          workLocation: 'Ottawa Civic',
          etaAlertThresholdsMinutes: const [30, 5],
        ),
      );
      await tester.pumpAndSettle();

      final thirtyCheckbox = tester.widget<CheckboxListTile>(find.byKey(const Key('eta_threshold_30')));
      final fiveCheckbox = tester.widget<CheckboxListTile>(find.byKey(const Key('eta_threshold_5')));
      final sixtyCheckbox = tester.widget<CheckboxListTile>(find.byKey(const Key('eta_threshold_60')));
      expect(thirtyCheckbox.value, true);
      expect(fiveCheckbox.value, true);
      expect(sixtyCheckbox.value, false);
    });

    testWidgets('disabling calls the service and never surfaces a failure', (tester) async {
      when(() => patientAlertService.disableAlerts('uid-1')).thenThrow(Exception('boom'));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Disable'));
      await tester.tap(find.text('Disable'));
      await tester.pumpAndSettle();

      verify(() => patientAlertService.disableAlerts('uid-1')).called(1);
      // Mirrors the Angular version: failures here are logged, not shown.
      expect(find.text('Disable'), findsOneWidget);
    });
  });

  testWidgets('the periodic re-check tick fires without error', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('the appearance control switches theme mode', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Dark'));
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.byType(UserSettingsScreen)));
    expect(container.read(themeModeProvider), ThemeMode.dark);
  });
}
