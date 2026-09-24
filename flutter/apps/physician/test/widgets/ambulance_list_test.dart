import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physician/classes/active_ambulance_location.dart';
import 'package:physician/services/ambulance_highlight_service.dart';
import 'package:physician/services/ambulance_location_service.dart';
import 'package:physician/widgets/ambulance_card.dart';
import 'package:physician/widgets/ambulance_list.dart';
import 'package:physician/widgets/multiple_ambulance_view.dart' show AmbulanceViewFilter;

import '../support/pump_app.dart';

class _FakeAmbulanceLocationController extends AmbulanceLocationController {
  _FakeAmbulanceLocationController(this._initial);
  final AmbulanceLocationState _initial;

  @override
  AmbulanceLocationState build() => _initial;
}

AmbulanceTrackingInfo _info(
  String ambulanceId, {
  double latitude = 45.4,
  double longitude = -75.7,
  bool isTransporting = false,
  AmbulanceStatus status = AmbulanceStatus.active,
  int updatedAtMs = 1000,
}) {
  return AmbulanceTrackingInfo(
    status: status,
    location: ActiveAmbulanceLocation(
      ambulanceId: ambulanceId,
      latitude: latitude,
      longitude: longitude,
      isTransporting: isTransporting,
      updatedAtMs: updatedAtMs,
    ),
  );
}

void main() {
  Future<ProviderContainer> pumpList(
    WidgetTester tester, {
    AmbulanceViewFilter filter = AmbulanceViewFilter.all,
    AmbulanceLocationState state = const AmbulanceLocationState(hasLoadedOnce: true),
  }) async {
    late ProviderContainer container;
    await pumpApp(
      tester,
      Builder(
        builder: (context) {
          container = ProviderScope.containerOf(context);
          return AmbulanceList(filter: filter);
        },
      ),
      overrides: [ambulanceLocationProvider.overrideWith(() => _FakeAmbulanceLocationController(state))],
    );
    return container;
  }

  testWidgets('shows a spinner before the first snapshot arrives', (tester) async {
    await pumpList(tester, state: const AmbulanceLocationState());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(AmbulanceCard), findsNothing);
  });

  testWidgets('shows the empty state once loaded with no ambulances at all', (tester) async {
    await pumpList(tester);
    await tester.pumpAndSettle();

    expect(find.text('No ambulances to show'), findsOneWidget);
  });

  testWidgets('emptyOnly filter shows its own empty-state copy when nothing is empty', (
    tester,
  ) async {
    await pumpList(
      tester,
      filter: AmbulanceViewFilter.emptyOnly,
      state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5', isTransporting: true)}),
    );
    // pumpAndSettle() is safe here (unlike the pulsing-pill cases
    // elsewhere in this file) — Unit 5 is filtered out of entries
    // entirely, so its "Transporting" StatusPill never actually mounts;
    // only the plain, non-animated EmptyState renders.
    await tester.pumpAndSettle();

    expect(find.text('No empty ambulances right now'), findsOneWidget);
  });

  testWidgets('all shows every known ambulance sorted by ambulanceId, regardless of isTransporting', (
    tester,
  ) async {
    await pumpList(
      tester,
      state: AmbulanceLocationState(
        hasLoadedOnce: true,
        info: {'Unit 9': _info('Unit 9', isTransporting: true), 'Unit 5': _info('Unit 5', isTransporting: false)},
      ),
    );
    // Not pumpAndSettle() — Unit 9's "Transporting" StatusPill pulses
    // forever (its own AnimationController..repeat()), which never
    // settles, same reasoning as every other indeterminate-animation case
    // in this codebase.
    await tester.pump();

    final ids = tester.widgetList<AmbulanceCard>(find.byType(AmbulanceCard)).map((c) => c.info.location.ambulanceId);
    expect(ids, ['Unit 5', 'Unit 9']);
  });

  testWidgets('emptyOnly hides transporting ambulances', (tester) async {
    await pumpList(
      tester,
      filter: AmbulanceViewFilter.emptyOnly,
      state: AmbulanceLocationState(
        hasLoadedOnce: true,
        info: {'Unit 5': _info('Unit 5', isTransporting: false), 'Unit 9': _info('Unit 9', isTransporting: true)},
      ),
    );
    // pumpAndSettle() is safe — Unit 9 (the only transporting, pulsing
    // one) is filtered out of entries entirely, so its StatusPill never
    // mounts; only Unit 5's non-animated "Empty" pill renders.
    await tester.pumpAndSettle();

    expect(find.byType(AmbulanceCard), findsOneWidget);
    expect(tester.widget<AmbulanceCard>(find.byType(AmbulanceCard)).info.location.ambulanceId, 'Unit 5');
  });

  testWidgets('tapping a card selects it in ambulanceHighlightProvider', (tester) async {
    final container = await pumpList(
      tester,
      state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AmbulanceCard));
    await tester.pump();

    expect(container.read(ambulanceHighlightProvider).selectedId, 'Unit 5');
  });

  testWidgets('hovering a card sets the hover id; leaving clears it', (tester) async {
    final container = await pumpList(
      tester,
      state: AmbulanceLocationState(hasLoadedOnce: true, info: {'Unit 5': _info('Unit 5')}),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.byType(AmbulanceCard)));
    await tester.pump();
    expect(container.read(ambulanceHighlightProvider).hoveredId, 'Unit 5');

    await gesture.moveTo(const Offset(0, 590));
    await tester.pump();
    expect(container.read(ambulanceHighlightProvider).hoveredId, isNull);
  });

  testWidgets('the card matching the current highlight renders highlighted', (tester) async {
    await pumpList(
      tester,
      state: AmbulanceLocationState(
        hasLoadedOnce: true,
        info: {'Unit 5': _info('Unit 5'), 'Unit 9': _info('Unit 9')},
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(AmbulanceCard, 'Unit 5').first);
    await tester.pumpAndSettle();

    final cards = tester.widgetList<AmbulanceCard>(find.byType(AmbulanceCard)).toList();
    expect(cards.firstWhere((c) => c.info.location.ambulanceId == 'Unit 5').highlighted, true);
    expect(cards.firstWhere((c) => c.info.location.ambulanceId == 'Unit 9').highlighted, false);
  });
}
