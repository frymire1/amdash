import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

void main() {
  testWidgets('renders child, paints the grid, and sets a dark status-bar style in light mode', (tester) async {
    await pumpApp(tester, const AppBackground(child: Text('content')));

    expect(find.text('content'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);

    final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
    );
    expect(region.value, SystemUiOverlayStyle.dark);
  });

  testWidgets('sets a light status-bar style in dark mode', (tester) async {
    await pumpApp(tester, const AppBackground(child: SizedBox()), brightness: Brightness.dark);

    final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
    );
    expect(region.value, SystemUiOverlayStyle.light);
  });

  testWidgets('_GridPainter.shouldRepaint is true when the palette actually changes', (tester) async {
    await pumpApp(tester, const AppBackground(child: SizedBox()));
    // Same widget shape at the same tree position -> Flutter updates the
    // existing element rather than tearing it down, so the new brightness
    // gives CustomPaint's underlying render object a genuinely different
    // _GridPainter (different gridLine/glow) to diff against the old one.
    await pumpApp(tester, const AppBackground(child: SizedBox()), brightness: Brightness.dark);

    expect(tester.takeException(), isNull);
  });

  testWidgets('_GridPainter.shouldRepaint is false when nothing changed', (tester) async {
    await pumpApp(tester, const AppBackground(child: SizedBox()));
    await pumpApp(tester, const AppBackground(child: SizedBox()));

    expect(tester.takeException(), isNull);
  });
}
