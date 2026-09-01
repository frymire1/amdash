import 'package:admin/screens/hospital_management_screen.dart';
import 'package:admin/services/admin_service.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockAdminService extends Mock implements AdminService {}

void main() {
  late _MockAdminService adminService;

  setUp(() {
    adminService = _MockAdminService();
  });

  testWidgets('hosts the page heading and HospitalManagementSection', (tester) async {
    await pumpApp(
      tester,
      const HospitalManagementScreen(),
      overrides: [
        adminServiceProvider.overrideWithValue(adminService),
        hospitalsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Hospitals'), findsWidgets);
    expect(find.text('No hospitals yet'), findsOneWidget);
  });
}
