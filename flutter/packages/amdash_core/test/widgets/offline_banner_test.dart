import 'package:amdash_core/amdash_core.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

void main() {
  group('isOfflineProvider', () {
    ProviderContainer containerFor(List<ConnectivityResult> results) {
      final container = ProviderContainer(
        overrides: [connectivityProvider.overrideWith((ref) => Stream.value(results))],
      );
      return container;
    }

    test('every result is none -> offline', () async {
      final container = containerFor([ConnectivityResult.none]);
      addTearDown(container.dispose);
      await container.read(connectivityProvider.future);

      expect(container.read(isOfflineProvider), true);
    });

    test('a real connection type -> online', () async {
      final container = containerFor([ConnectivityResult.wifi]);
      addTearDown(container.dispose);
      await container.read(connectivityProvider.future);

      expect(container.read(isOfflineProvider), false);
    });

    test('an empty result list -> online (not treated as "all none")', () async {
      final container = containerFor(const []);
      addTearDown(container.dispose);
      await container.read(connectivityProvider.future);

      expect(container.read(isOfflineProvider), false);
    });

    test('still loading/errored (orElse) -> online', () async {
      final container = ProviderContainer(
        overrides: [connectivityProvider.overrideWith((ref) => const Stream<List<ConnectivityResult>>.empty())],
      );
      addTearDown(container.dispose);

      // An empty stream never emits -> connectivityProvider stays
      // AsyncLoading -> isOfflineProvider's maybeWhen orElse branch.
      expect(container.read(isOfflineProvider), false);
    });
  });

  group('OfflineBanner', () {
    testWidgets('renders nothing while online', (tester) async {
      await pumpApp(
        tester,
        const OfflineBanner(),
        overrides: [isOfflineProvider.overrideWithValue(false)],
      );

      expect(find.text('You are offline. Some features may not work.'), findsNothing);
    });

    testWidgets('renders the warning banner while offline', (tester) async {
      await pumpApp(
        tester,
        const OfflineBanner(),
        overrides: [isOfflineProvider.overrideWithValue(true)],
      );

      expect(find.text('You are offline. Some features may not work.'), findsOneWidget);
    });
  });
}
