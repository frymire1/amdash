import 'package:admin/widgets/admin_page.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

void main() {
  testWidgets('AdminPage renders its children in order', (tester) async {
    await pumpApp(
      tester,
      const AdminPage(children: [Text('First'), Text('Second')]),
    );
    await tester.pumpAndSettle();

    // Also the harness-proving checkpoint for this app (Stage C2): if
    // buildLightTheme()'s GoogleFonts.outfit(...) call were to fire a real
    // network fetch instead of respecting flutter_test_config.dart's
    // allowRuntimeFetching guard, it would surface here as an uncaught
    // exception.
    expect(tester.takeException(), isNull);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('AdminCard wraps its child in a padded Card', (tester) async {
    await pumpApp(tester, const AdminCard(child: Text('Content')));
    await tester.pumpAndSettle();

    expect(find.ancestor(of: find.text('Content'), matching: find.byType(Card)), findsOneWidget);
  });

  group('FormMessage', () {
    testWidgets('an error message uses the theme error color', (tester) async {
      await pumpApp(tester, const FormMessage(text: 'Something failed.', isError: true));
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text('Something failed.'));
      final context = tester.element(find.text('Something failed.'));
      expect(text.style!.color, Theme.of(context).colorScheme.error);
    });

    testWidgets('a success message uses the palette success color', (tester) async {
      await pumpApp(tester, const FormMessage(text: 'Saved.', isError: false));
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text('Saved.'));
      final context = tester.element(find.text('Saved.'));
      expect(text.style!.color, context.palette.success);
    });
  });
}
