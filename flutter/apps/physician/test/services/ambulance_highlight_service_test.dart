import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physician/services/ambulance_highlight_service.dart';

void main() {
  group('AmbulanceHighlightState', () {
    test('effectiveId prefers hoveredId over selectedId', () {
      const state = AmbulanceHighlightState(selectedId: 'Unit 5', hoveredId: 'Unit 9');
      expect(state.effectiveId, 'Unit 9');
    });

    test('effectiveId falls back to selectedId when nothing is hovered', () {
      const state = AmbulanceHighlightState(selectedId: 'Unit 5');
      expect(state.effectiveId, 'Unit 5');
    });

    test('effectiveId is null when neither is set', () {
      const state = AmbulanceHighlightState();
      expect(state.effectiveId, isNull);
    });
  });

  group('AmbulanceHighlightController', () {
    late ProviderContainer container;

    setUp(() => container = ProviderContainer());
    tearDown(() => container.dispose());

    test('starts with nothing selected or hovered', () {
      final state = container.read(ambulanceHighlightProvider);
      expect(state.selectedId, isNull);
      expect(state.hoveredId, isNull);
    });

    test('select sets selectedId without disturbing an existing hover', () {
      final notifier = container.read(ambulanceHighlightProvider.notifier);
      notifier.hover('Unit 9');
      notifier.select('Unit 5');

      final state = container.read(ambulanceHighlightProvider);
      expect(state.selectedId, 'Unit 5');
      expect(state.hoveredId, 'Unit 9');
    });

    test('select(null) clears the selection', () {
      final notifier = container.read(ambulanceHighlightProvider.notifier);
      notifier.select('Unit 5');
      notifier.select(null);

      expect(container.read(ambulanceHighlightProvider).selectedId, isNull);
    });

    test('hover sets hoveredId without disturbing an existing selection', () {
      final notifier = container.read(ambulanceHighlightProvider.notifier);
      notifier.select('Unit 5');
      notifier.hover('Unit 9');

      final state = container.read(ambulanceHighlightProvider);
      expect(state.selectedId, 'Unit 5');
      expect(state.hoveredId, 'Unit 9');
    });

    test('hover(null) (mouse leaving) clears the hover, revealing the latched selection', () {
      final notifier = container.read(ambulanceHighlightProvider.notifier);
      notifier.select('Unit 5');
      notifier.hover('Unit 9');
      notifier.hover(null);

      final state = container.read(ambulanceHighlightProvider);
      expect(state.hoveredId, isNull);
      expect(state.effectiveId, 'Unit 5');
    });
  });
}
