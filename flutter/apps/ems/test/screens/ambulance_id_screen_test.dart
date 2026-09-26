import 'dart:async';

import 'package:ems/screens/ambulance_id_screen.dart';
import 'package:ems/services/ambulance_id_service.dart';
import 'package:ems/services/ambulance_phone_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/pump_app.dart';

class _MockAmbulanceIdService extends Mock implements AmbulanceIdService {}

class _MockAmbulancePhoneService extends Mock implements AmbulancePhoneService {}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    AmbulanceIdService? service,
    AmbulancePhoneService? phoneService,
  }) {
    return pumpApp(
      tester,
      const SizedBox(),
      overrides: [
        if (service != null) ambulanceIdServiceProvider.overrideWithValue(service),
        if (phoneService != null) ambulancePhoneServiceProvider.overrideWithValue(phoneService),
      ],
      routes: {'/ambulance-id': (_) => const AmbulanceIdScreen()},
      initialLocation: '/ambulance-id',
    );
  }

  // Every "successful submit" test needs both fields valid — the real
  // (SharedPreferences-backed) AmbulancePhoneService, used whenever a test
  // doesn't need to mock/verify it specifically, saves silently against
  // the mocked prefs from setUp above.
  Future<void> fillValidForm(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('ambulance_id_field')), 'Unit 5');
    await tester.enterText(find.byKey(const Key('ambulance_phone_field')), '555-0123');
  }

  testWidgets('submitting with both fields empty shows both validation errors and saves nothing', (tester) async {
    final service = _MockAmbulanceIdService();
    final phoneService = _MockAmbulancePhoneService();
    await pumpScreen(tester, service: service, phoneService: phoneService);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Enter the ambulance ID.'), findsOneWidget);
    expect(find.text('Enter a phone number.'), findsOneWidget);
    verifyNever(() => service.save(any()));
    verifyNever(() => phoneService.save(any()));
  });

  testWidgets('tapping outside a field marks it touched and shows both errors while still empty', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    // onTapOutside only fires once the field is actually focused (same
    // reasoning as WorkLocationScreen's identical test) — focus it first,
    // then tap a known on-screen widget outside its bounds.
    await tester.tap(find.byKey(const Key('ambulance_id_field')));
    await tester.pump();
    await tester.tap(find.text('What ambulance are you in today?'));
    await tester.pumpAndSettle();

    expect(find.text('Enter the ambulance ID.'), findsOneWidget);
    expect(find.text('Enter a phone number.'), findsOneWidget);
  });

  testWidgets('typing an ID over the max length shows the length-specific error', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('ambulance_id_field')), 'x' * 101);
    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Must be 100 characters or fewer.'), findsOneWidget);
  });

  testWidgets('typing a phone number over the max length shows the length-specific error', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('ambulance_phone_field')), 'x' * 31);
    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Must be 30 characters or fewer.'), findsOneWidget);
  });

  testWidgets('entering valid values and submitting saves both and navigates home', (tester) async {
    final service = _MockAmbulanceIdService();
    final phoneService = _MockAmbulancePhoneService();
    when(() => service.save(any())).thenAnswer((_) async {});
    when(() => phoneService.save(any())).thenAnswer((_) async {});

    await pumpScreen(tester, service: service, phoneService: phoneService);
    await tester.pumpAndSettle();

    await fillValidForm(tester);
    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pumpAndSettle();

    verify(() => service.save('Unit 5')).called(1);
    verify(() => phoneService.save('555-0123')).called(1);
    expect(find.byKey(pumpAppHomeKey), findsOneWidget);
  });

  testWidgets('submitting via the keyboard action (onSubmitted) saves the same as tapping Continue', (tester) async {
    final service = _MockAmbulanceIdService();
    final phoneService = _MockAmbulancePhoneService();
    when(() => service.save(any())).thenAnswer((_) async {});
    when(() => phoneService.save(any())).thenAnswer((_) async {});

    await pumpScreen(tester, service: service, phoneService: phoneService);
    await tester.pumpAndSettle();

    await fillValidForm(tester);
    // receiveAction fires on whichever field currently holds focus —
    // fillValidForm's enterText calls leave the phone field focused
    // (entered last), so re-focus the ID field to specifically exercise
    // its own onSubmitted, not just the phone field's.
    await tester.tap(find.byKey(const Key('ambulance_id_field')));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    verify(() => service.save('Unit 5')).called(1);
    verify(() => phoneService.save('555-0123')).called(1);
    expect(find.byKey(pumpAppHomeKey), findsOneWidget);
  });

  testWidgets('submitting via the keyboard action on the phone field (its own onSubmitted) also saves', (
    tester,
  ) async {
    final service = _MockAmbulanceIdService();
    final phoneService = _MockAmbulancePhoneService();
    when(() => service.save(any())).thenAnswer((_) async {});
    when(() => phoneService.save(any())).thenAnswer((_) async {});

    await pumpScreen(tester, service: service, phoneService: phoneService);
    await tester.pumpAndSettle();

    // fillValidForm's enterText calls leave the phone field focused
    // (entered last) — no extra tap needed to exercise its own
    // onSubmitted specifically.
    await fillValidForm(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    verify(() => service.save('Unit 5')).called(1);
    verify(() => phoneService.save('555-0123')).called(1);
    expect(find.byKey(pumpAppHomeKey), findsOneWidget);
  });

  testWidgets('leading/trailing whitespace is trimmed before saving, on both fields', (tester) async {
    final service = _MockAmbulanceIdService();
    final phoneService = _MockAmbulancePhoneService();
    when(() => service.save(any())).thenAnswer((_) async {});
    when(() => phoneService.save(any())).thenAnswer((_) async {});

    await pumpScreen(tester, service: service, phoneService: phoneService);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('ambulance_id_field')), '  Unit 5  ');
    await tester.enterText(find.byKey(const Key('ambulance_phone_field')), '  555-0123  ');
    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pumpAndSettle();

    verify(() => service.save('Unit 5')).called(1);
    verify(() => phoneService.save('555-0123')).called(1);
  });

  testWidgets('save timing out shows the connection-specific message', (tester) async {
    final service = _MockAmbulanceIdService();
    // Never resolves — the real 15s .timeout() inside _submit is what
    // fires, not a manufactured TimeoutException from the mock, matching
    // WorkLocationScreen's own test convention for this exact case. The
    // phone side uses the real (fast) SharedPreferences-backed service —
    // Future.wait still only completes once BOTH are done, so a single
    // hanging future is enough to prove the whole submit times out.
    when(() => service.save(any())).thenAnswer((_) => Completer<void>().future);

    await pumpScreen(tester, service: service);
    await tester.pumpAndSettle();

    await fillValidForm(tester);
    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    await tester.pump();

    expect(find.text('This is taking longer than expected. Check your connection and try again.'), findsOneWidget);
  });

  testWidgets('the ID service failing generically shows the generic error', (tester) async {
    final service = _MockAmbulanceIdService();
    when(() => service.save(any())).thenThrow(Exception('boom'));

    await pumpScreen(tester, service: service);
    await tester.pumpAndSettle();

    await fillValidForm(tester);
    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Failed to save. Please try again.'), findsOneWidget);
  });

  testWidgets('the phone service failing generically also shows the generic error', (tester) async {
    final phoneService = _MockAmbulancePhoneService();
    when(() => phoneService.save(any())).thenThrow(Exception('boom'));

    await pumpScreen(tester, phoneService: phoneService);
    await tester.pumpAndSettle();

    await fillValidForm(tester);
    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Failed to save. Please try again.'), findsOneWidget);
  });
}
