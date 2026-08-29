import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/pump_app.dart';

// See TESTING.md's MockPlatformInterfaceMixin note — url_launcher's own
// UrlLauncherPlatform extends PlatformInterface too (same as
// GeolocatorPlatform/FlutterForegroundTaskPlatform), confirmed via its
// source. Same technique, second use in this repo.
class _MockUrlLauncherPlatform extends Mock with MockPlatformInterfaceMixin implements UrlLauncherPlatform {}

class _MockAuthService extends Mock implements AuthService {}

void main() {
  setUpAll(() {
    registerFallbackValue(const LaunchOptions());
  });

  late _MockUrlLauncherPlatform urlLauncher;
  late UrlLauncherPlatform realUrlLauncher;
  late _MockAuthService authService;

  setUp(() {
    urlLauncher = _MockUrlLauncherPlatform();
    realUrlLauncher = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = urlLauncher;
    when(() => urlLauncher.launchUrl(any(), any())).thenAnswer((_) async => true);

    authService = _MockAuthService();
    when(() => authService.signOut()).thenAnswer((_) async {});
  });

  tearDown(() => UrlLauncherPlatform.instance = realUrlLauncher);

  Future<void> pumpScreen(WidgetTester tester, {UserProfile? profile}) {
    return pumpApp(
      tester,
      const AccessDeniedScreen(appName: 'Physician'),
      overrides: [
        userProfileProvider.overrideWith((ref) => Stream.value(profile)),
        authServiceProvider.overrideWithValue(authService),
      ],
    );
  }

  testWidgets('a physician/nurse role shows only the Physician app link', (tester) async {
    await pumpScreen(tester, profile: const UserProfile(role: [UserRole.nurse]));
    await tester.pump();

    expect(find.text('Physician app'), findsOneWidget);
    expect(find.text('EMS app'), findsNothing);
    expect(find.text('Admin app'), findsNothing);
  });

  testWidgets('an ems role shows only the EMS app link', (tester) async {
    await pumpScreen(tester, profile: const UserProfile(role: [UserRole.ems]));
    await tester.pump();

    expect(find.text('EMS app'), findsOneWidget);
    expect(find.text('Physician app'), findsNothing);
  });

  testWidgets('admin/super-admin roles show the Admin app link', (tester) async {
    await pumpScreen(tester, profile: const UserProfile(role: [UserRole.superAdmin]));
    await tester.pump();

    expect(find.text('Admin app'), findsOneWidget);
  });

  testWidgets('no matching role at all hides the "other apps" section entirely', (tester) async {
    await pumpScreen(tester, profile: const UserProfile(role: []));
    await tester.pump();

    expect(find.text('Try one of your other apps:'), findsNothing);
  });

  testWidgets('tapping the Physician app button launches its real URL', (tester) async {
    await pumpScreen(tester, profile: const UserProfile(role: [UserRole.physician]));
    await tester.pump();

    await tester.tap(find.text('Physician app'));
    await tester.pump();

    verify(() => urlLauncher.launchUrl(AppUrls.physician, any())).called(1);
  });

  testWidgets('Log out calls authServiceProvider.signOut()', (tester) async {
    await pumpScreen(tester);
    await tester.pump();

    await tester.tap(find.text('Log out'));
    await tester.pump();

    verify(() => authService.signOut()).called(1);
  });
}
