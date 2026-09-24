import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physician/classes/active_ambulance_location.dart';
import 'package:physician/services/ambulance_location_service.dart';
import 'package:physician/widgets/ambulance_card.dart';

AmbulanceTrackingInfo _info({
  String ambulanceId = 'Unit 5',
  double latitude = 45.4215,
  double longitude = -75.6972,
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
  Future<void> pumpCard(
    WidgetTester tester, {
    AmbulanceTrackingInfo? info,
    bool highlighted = false,
    VoidCallback? onTap,
    ValueChanged<bool>? onHoverChanged,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // Constrained and top-left-aligned, not filling the whole
          // surface — the hover test below needs real empty space
          // elsewhere on screen to move the pointer into, or "moving
          // away" would still land inside the card's own MouseRegion.
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: AmbulanceCard(
                info: info ?? _info(),
                highlighted: highlighted,
                onTap: onTap ?? () {},
                onHoverChanged: onHoverChanged ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders the ambulance id and formatted coordinates', (tester) async {
    await pumpCard(tester, info: _info(ambulanceId: 'Unit 5', latitude: 45.4215, longitude: -75.6972));

    expect(find.text('Unit 5'), findsOneWidget);
    expect(find.text('45.4215, -75.6972'), findsOneWidget);
  });

  testWidgets('an active transporting ambulance shows a pulsing "Transporting" pill', (tester) async {
    await pumpCard(tester, info: _info(isTransporting: true));

    // StatusPill renders its label uppercase — see that widget's own
    // build().
    expect(find.text('TRANSPORTING'), findsOneWidget);
  });

  testWidgets('an active empty ambulance shows an "Empty" pill', (tester) async {
    await pumpCard(tester, info: _info(isTransporting: false));

    expect(find.text('EMPTY'), findsOneWidget);
  });

  testWidgets('a stale ambulance shows "Lost Connection" regardless of isTransporting', (tester) async {
    await pumpCard(tester, info: _info(isTransporting: true, status: AmbulanceStatus.stale));

    expect(find.text('LOST CONNECTION'), findsOneWidget);
    expect(find.text('TRANSPORTING'), findsNothing);
  });

  testWidgets('tapping the card calls onTap', (tester) async {
    var tapped = false;
    await pumpCard(tester, onTap: () => tapped = true);

    await tester.tap(find.byType(AmbulanceCard));
    expect(tapped, true);
  });

  testWidgets('hovering the card reports true, and moving away reports false', (tester) async {
    final hoverEvents = <bool>[];
    await pumpCard(tester, onHoverChanged: hoverEvents.add);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.byType(AmbulanceCard)));
    await tester.pump();

    // Clearly outside the constrained, top-left-aligned card (see
    // pumpCard) — the default 800x600 test surface always has empty
    // space in this corner.
    await gesture.moveTo(const Offset(700, 500));
    await tester.pump();

    expect(hoverEvents, [true, false]);
  });

  testWidgets('highlighted draws a tracking-accent border; not highlighted draws none', (tester) async {
    await pumpCard(tester, highlighted: true);
    var card = tester.widget<Card>(find.byType(Card));
    var shape = card.shape! as RoundedRectangleBorder;
    expect(shape.side.width, 2);

    await pumpCard(tester, highlighted: false);
    card = tester.widget<Card>(find.byType(Card));
    shape = card.shape! as RoundedRectangleBorder;
    expect(shape.side, BorderSide.none);
  });
}
