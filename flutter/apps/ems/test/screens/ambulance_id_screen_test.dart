import 'dart:async';

import 'package:ems/screens/ambulance_id_screen.dart';
import 'package:ems/services/ambulance_id_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/pump_app.dart';

class _MockAmbulanceIdService extends Mock implements AmbulanceIdService {}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester, {AmbulanceIdService? service}) {
    return pumpApp(
      tester,
      const SizedBox(),
      overrides: [if (service != null) ambulanceIdServiceProvider.overrideWithValue(service)],
      routes: {'/ambulance-id': (_) => const AmbulanceIdScreen()},
      initialLocation: '/ambulance-id',
    );
  }

  testWidgets('submitting with an empty field shows the validation error and saves nothing', (tester) async {
    final service = _MockAmbulanceIdService();
    await pumpScreen(tester, service: service);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Enter the ambulance ID.'), findsOneWidget);
    verifyNever(() => service.save(any()));
  });

  testWidgets('tapping outside the field marks it touched and shows the error while still empty', (tester) async {
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
  });

  testWidgets('typing a value over the max length shows the length-specific error', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('ambulance_id_field')), 'x' * 101);
    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Must be 100 characters or fewer.'), findsOneWidget);
  });

  testWidgets('entering a valid ID and submitting saves it and navigates home', (tester) async {
    final service = _MockAmbulanceIdService();
    when(() => service.save(any())).thenAnswer((_) async {});

    await pumpScreen(tester, service: service);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('ambulance_id_field')), 'Unit 5');
    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pumpAndSettle();

    verify(() => service.save('Unit 5')).called(1);
    expect(find.byKey(pumpAppHomeKey), findsOneWidget);
  });

  testWidgets('submitting via the keyboard action (onSubmitted) saves the same as tapping Continue', (tester) async {
    final service = _MockAmbulanceIdService();
    when(() => service.save(any())).thenAnswer((_) async {});

    await pumpScreen(tester, service: service);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('ambulance_id_field')), 'Unit 5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    verify(() => service.save('Unit 5')).called(1);
    expect(find.byKey(pumpAppHomeKey), findsOneWidget);
  });

  testWidgets('leading/trailing whitespace is trimmed before saving', (tester) async {
    final service = _MockAmbulanceIdService();
    when(() => service.save(any())).thenAnswer((_) async {});

    await pumpScreen(tester, service: service);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('ambulance_id_field')), '  Unit 5  ');
    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pumpAndSettle();

    verify(() => service.save('Unit 5')).called(1);
  });

  testWidgets('save timing out shows the connection-specific message', (tester) async {
    final service = _MockAmbulanceIdService();
    // Never resolves — the real 15s .timeout() inside _submit is what
    // fires, not a manufactured TimeoutException from the mock, matching
    // WorkLocationScreen's own test convention for this exact case.
    when(() => service.save(any())).thenAnswer((_) => Completer<void>().future);

    await pumpScreen(tester, service: service);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('ambulance_id_field')), 'Unit 5');
    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    await tester.pump();

    expect(find.text('This is taking longer than expected. Check your connection and try again.'), findsOneWidget);
  });

  testWidgets('save failing generically shows the generic error', (tester) async {
    final service = _MockAmbulanceIdService();
    when(() => service.save(any())).thenThrow(Exception('boom'));

    await pumpScreen(tester, service: service);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('ambulance_id_field')), 'Unit 5');
    await tester.tap(find.byKey(const Key('ambulance_id_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Failed to save. Please try again.'), findsOneWidget);
  });
}
