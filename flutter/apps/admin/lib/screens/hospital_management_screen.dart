import 'package:flutter/material.dart';

import '../widgets/admin_page.dart';
import '../widgets/hospital_management_section.dart';

/// Its own route/tab again, not folded into [OrganizationSettingsScreen] —
/// [HospitalManagementSection]'s own doc comment records that this used to
/// be the case (hospitals treated as an org-level setting like retention,
/// not a separate management domain the way users are) before being
/// deliberately consolidated into Settings; this screen reverses that call.
/// [HospitalManagementSection] itself stays title-less by design (see its
/// own comment), so this screen supplies the page heading every other
/// top-level admin screen has.
class HospitalManagementScreen extends StatelessWidget {
  const HospitalManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AdminPage(
      children: [
        Text('Hospitals', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        SizedBox(height: 16),
        HospitalManagementSection(),
      ],
    );
  }
}
