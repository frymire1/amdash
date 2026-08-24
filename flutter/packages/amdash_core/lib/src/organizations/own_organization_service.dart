import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/user_profile_service.dart';
import '../models/organization.dart';

/// A live listener on the caller's own `organizations/{organizationId}` —
/// legal per `firestore.rules`' `sameOrgAsCaller(orgId)` `get` for any
/// same-org member, not just an admin. Originally admin-only (backing
/// `organization_settings_screen.dart`'s toggles), promoted here once EMS
/// and physician also needed to read `fhirExportEnabled` to decide
/// whether to show the "Export FHIR record" action — admin's own
/// `organizationsProvider` (an *unconstrained* listener across every org,
/// only legal for a super-admin) stays private to that app, since nothing
/// else needs it.
final ownOrganizationProvider = StreamProvider<Organization?>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  final organizationId = profile?.organizationId;

  if (organizationId == null) {
    return Stream.value(null);
  }

  return FirebaseFirestore.instance.collection('organizations').doc(organizationId).snapshots().map((doc) {
    final data = doc.data();
    return data == null ? null : Organization.fromFirestore(doc.id, data);
  });
});
