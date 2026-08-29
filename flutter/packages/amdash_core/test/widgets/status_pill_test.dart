import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

// Every AnimatedBuilder assertion below is scoped to StatusPill's own
// subtree (find.descendant(...)), not a bare find.byType(AnimatedBuilder) —
// confirmed via a failing run that Flutter's own Navigator/_ModalScope
// machinery (which every pumped MaterialApp mounts, even for a plain
// `home:` route) wraps its content in an AnimatedBuilder of its own (over
// a restorationScopeId ValueNotifier, unrelated to StatusPill's ticker).
// An unscoped finder always finds that ambient one too, so
// "findsNothing"/"findsOneWidget" against the whole tree is simply wrong
// regardless of StatusPill's own behavior.
Finder _dotAnimatedBuilder() =>
    find.descendant(of: find.byType(StatusPill), matching: find.byType(AnimatedBuilder));

void main() {
  group('kind -> color mapping (via MediaQuery(disableAnimations: true), no ticker involved)', () {
    for (final kind in StatusPillKind.values) {
      testWidgets('renders the uppercased label for $kind', (tester) async {
        await pumpApp(
          tester,
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: StatusPill(kind: kind, label: 'tracking online', pulsing: true),
          ),
        );

        expect(find.text('TRACKING ONLINE'), findsOneWidget);
        // disableAnimations forces shouldAnimate to false even though
        // pulsing: true was passed -> no AnimationController/AnimatedBuilder
        // is ever created for this kind.
        expect(_dotAnimatedBuilder(), findsNothing);
      });
    }
  });

  group('non-pulsing', () {
    testWidgets('renders the static dot, no AnimatedBuilder', (tester) async {
      await pumpApp(tester, const StatusPill(kind: StatusPillKind.active, label: 'idle'));

      expect(_dotAnimatedBuilder(), findsNothing);
    });
  });

  group('pulsing (real ticker — pump-with-explicit-durations, never pumpAndSettle)', () {
    testWidgets('creates an AnimationController and rebuilds _Dot over time', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: const Scaffold(body: StatusPill(kind: StatusPillKind.active, label: 'tracking', pulsing: true)),
        ),
      );

      expect(_dotAnimatedBuilder(), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling pulsing off disposes the controller (didUpdateWidget)', (tester) async {
      final key = GlobalKey();
      Widget build(bool pulsing) => MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(body: StatusPill(key: key, kind: StatusPillKind.active, label: 'tracking', pulsing: pulsing)),
      );

      await tester.pumpWidget(build(true));
      expect(_dotAnimatedBuilder(), findsOneWidget);

      await tester.pumpWidget(build(false));
      await tester.pump();
      expect(_dotAnimatedBuilder(), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('disposes the controller on unmount without throwing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: const Scaffold(body: StatusPill(kind: StatusPillKind.active, label: 'tracking', pulsing: true)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      expect(tester.takeException(), isNull);
    });
  });
}
