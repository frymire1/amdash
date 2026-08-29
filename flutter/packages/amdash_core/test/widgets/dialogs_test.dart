import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

/// A button whose tap kicks off [action] and stashes its eventual result
/// in [result] — the simplest way to drive/observe one of this file's
/// `Future<T>`-returning dialog functions from a widget test.
class _Trigger<T> extends StatelessWidget {
  const _Trigger({required this.action, required this.result});

  final Future<T> Function(BuildContext) action;
  final ValueNotifier<T?> result;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () async => result.value = await action(context),
          child: const Text('trigger'),
        ),
      ),
    );
  }
}

void main() {
  group('showConfirmDialog', () {
    testWidgets('tapping Cancel resolves false', (tester) async {
      final result = ValueNotifier<bool?>(null);
      await pumpApp(
        tester,
        _Trigger<bool>(
          action: (context) => showConfirmDialog(context, title: 'Delete?', message: 'Are you sure?'),
          result: result,
        ),
      );

      await tester.tap(find.text('trigger'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result.value, false);
    });

    testWidgets('tapping the confirm label resolves true', (tester) async {
      final result = ValueNotifier<bool?>(null);
      await pumpApp(
        tester,
        _Trigger<bool>(
          action: (context) =>
              showConfirmDialog(context, title: 'Delete?', message: 'Are you sure?', confirmLabel: 'Delete'),
          result: result,
        ),
      );

      await tester.tap(find.text('trigger'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(result.value, true);
    });

    testWidgets('dismissing without a choice falls back to false', (tester) async {
      final result = ValueNotifier<bool?>(null);
      await pumpApp(
        tester,
        _Trigger<bool>(
          action: (context) => showConfirmDialog(context, title: 'Delete?', message: 'Are you sure?'),
          result: result,
        ),
      );

      await tester.tap(find.text('trigger'));
      await tester.pumpAndSettle();
      // Dismiss via the barrier (no explicit pop(value)) -> showDialog's
      // own Future resolves with null, exercising the `?? false` fallback.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(result.value, false);
    });
  });

  group('showErrorDialog', () {
    testWidgets('renders the title/message and OK dismisses it', (tester) async {
      final result = ValueNotifier<void>(null);
      var completed = false;
      await pumpApp(
        tester,
        _Trigger<void>(
          action: (context) async {
            await showErrorDialog(context, title: 'Upload failed', message: "Couldn't reach the server.");
            completed = true;
          },
          result: result,
        ),
      );

      await tester.tap(find.text('trigger'));
      await tester.pumpAndSettle();
      expect(find.text('Upload failed'), findsOneWidget);
      expect(find.text("Couldn't reach the server."), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(completed, true);
    });
  });

  group('showReauthPasswordDialog', () {
    testWidgets('the obscure-toggle icon flips TextField.obscureText', (tester) async {
      final result = ValueNotifier<String?>(null);
      await pumpApp(
        tester,
        _Trigger<String?>(action: showReauthPasswordDialog, result: result),
      );

      await tester.tap(find.text('trigger'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).obscureText, true);

      await tester.tap(find.byIcon(Icons.visibility_off));
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).obscureText, false);
    });

    testWidgets('submitting an empty value does not pop the dialog', (tester) async {
      final result = ValueNotifier<String?>(null);
      await pumpApp(
        tester,
        _Trigger<String?>(action: showReauthPasswordDialog, result: result),
      );

      await tester.tap(find.text('trigger'));
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets('Continue with a non-empty value pops with the typed password', (tester) async {
      final result = ValueNotifier<String?>(null);
      await pumpApp(
        tester,
        _Trigger<String?>(action: showReauthPasswordDialog, result: result),
      );

      await tester.tap(find.text('trigger'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'hunter2');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(result.value, 'hunter2');
    });

    testWidgets('Cancel pops with null', (tester) async {
      final result = ValueNotifier<String?>(null);
      await pumpApp(
        tester,
        _Trigger<String?>(action: showReauthPasswordDialog, result: result),
      );

      await tester.tap(find.text('trigger'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'hunter2');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result.value, isNull);
    });

    testWidgets('submitting a non-empty value via the keyboard action pops with it', (tester) async {
      final result = ValueNotifier<String?>(null);
      await pumpApp(
        tester,
        _Trigger<String?>(action: showReauthPasswordDialog, result: result),
      );

      await tester.tap(find.text('trigger'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'hunter2');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(result.value, 'hunter2');
    });
  });
}
