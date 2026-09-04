import 'package:ems/services/battery_watch_service.dart';
import 'package:ems/widgets/battery_warning_banner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

// See TESTING.md's "Notifier-backed provider a test needs to mutate"
// convention — same shape as _FakeEmsTrackingController etc. elsewhere in
// this app's own test suite.
class _FakeBatteryWatchController extends BatteryWatchController {
  _FakeBatteryWatchController(this._initial);
  final bool _initial;

  @override
  bool build() => _initial;
}

void main() {
  group('BatteryWarningBanner', () {
    testWidgets('renders nothing while battery is not low', (tester) async {
      await pumpApp(
        tester,
        const BatteryWarningBanner(),
        overrides: [batteryWatchProvider.overrideWith(() => _FakeBatteryWatchController(false))],
      );

      expect(
        find.text('Battery low — tracking may stop soon. Plug in or hand off if possible.'),
        findsNothing,
      );
    });

    testWidgets('renders the warning banner while battery is low', (tester) async {
      await pumpApp(
        tester,
        const BatteryWarningBanner(),
        overrides: [batteryWatchProvider.overrideWith(() => _FakeBatteryWatchController(true))],
      );

      expect(
        find.text('Battery low — tracking may stop soon. Plug in or hand off if possible.'),
        findsOneWidget,
      );
    });
  });
}
