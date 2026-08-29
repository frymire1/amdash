import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

void main() {
  testWidgets('renders child inside a blurred, rounded surface', (tester) async {
    await pumpApp(
      tester,
      const GlassPanel(child: Text('panel content')),
    );

    expect(find.text('panel content'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(ClipRRect), findsOneWidget);
  });

  testWidgets('resolves AppPalette.light in the light theme', (tester) async {
    late BuildContext capturedContext;
    await pumpApp(
      tester,
      Builder(
        builder: (context) {
          capturedContext = context;
          return const GlassPanel(child: SizedBox());
        },
      ),
    );

    final decoratedBox = tester.widget<DecoratedBox>(find.byType(DecoratedBox));
    final decoration = decoratedBox.decoration as BoxDecoration;
    expect(decoration.color, capturedContext.palette.glassSurface);
    expect(capturedContext.palette.glassSurface, AppPalette.light.glassSurface);
  });

  testWidgets('resolves AppPalette.dark in the dark theme', (tester) async {
    late BuildContext capturedContext;
    await pumpApp(
      tester,
      Builder(
        builder: (context) {
          capturedContext = context;
          return const GlassPanel(child: SizedBox());
        },
      ),
      brightness: Brightness.dark,
    );

    expect(capturedContext.palette.glassSurface, AppPalette.dark.glassSurface);
  });

  testWidgets('a custom borderRadius overrides the default AppRadius.md', (tester) async {
    await pumpApp(
      tester,
      const GlassPanel(borderRadius: BorderRadius.all(Radius.circular(99)), child: SizedBox()),
    );

    final clipRRect = tester.widget<ClipRRect>(find.byType(ClipRRect));
    expect(clipRRect.borderRadius, const BorderRadius.all(Radius.circular(99)));
  });
}
