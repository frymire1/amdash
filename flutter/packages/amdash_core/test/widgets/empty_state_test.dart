import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

void main() {
  group('EmptyStateIllustration', () {
    testWidgets('paints the routePing graphic (default)', (tester) async {
      await pumpApp(tester, const EmptyStateIllustration());
      expect(tester.takeException(), isNull);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('paints the chartPulse graphic', (tester) async {
      await pumpApp(tester, const EmptyStateIllustration(graphic: EmptyStateGraphic.chartPulse));
      expect(tester.takeException(), isNull);
    });

    testWidgets('repaints when the palette changes (light -> dark)', (tester) async {
      await pumpApp(tester, const EmptyStateIllustration(graphic: EmptyStateGraphic.chartPulse));
      await pumpApp(
        tester,
        const EmptyStateIllustration(graphic: EmptyStateGraphic.chartPulse),
        brightness: Brightness.dark,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('routePing repaints when the palette changes (light -> dark)', (tester) async {
      await pumpApp(tester, const EmptyStateIllustration());
      await pumpApp(tester, const EmptyStateIllustration(), brightness: Brightness.dark);
      expect(tester.takeException(), isNull);
    });

    testWidgets('respects a custom size', (tester) async {
      await pumpApp(tester, const EmptyStateIllustration(size: 64));
      final sizedBox = tester.widget<SizedBox>(find.byType(SizedBox).first);
      expect(sizedBox.width, 64);
      expect(sizedBox.height, 64);
    });
  });

  group('EmptyState', () {
    testWidgets('top-aligned (default) renders title/subtitle', (tester) async {
      await pumpApp(
        tester,
        const EmptyState(title: 'No patients', subtitle: 'Upload one to get started'),
      );

      expect(find.text('No patients'), findsOneWidget);
      expect(find.text('Upload one to get started'), findsOneWidget);

      final align = tester.widget<Align>(find.byType(Align));
      expect(align.alignment, Alignment.topCenter);
    });

    testWidgets('centered renders without a subtitle', (tester) async {
      await pumpApp(
        tester,
        const EmptyState(title: 'Select a patient to view details', centered: true),
      );

      expect(find.text('Select a patient to view details'), findsOneWidget);
      final align = tester.widget<Align>(find.byType(Align));
      expect(align.alignment, Alignment.center);
    });
  });
}
