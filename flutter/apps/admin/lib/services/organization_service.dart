import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Mirrors `apps/admin/src/app/services/organization.service.ts`: an
/// unconstrained live listener across *every* organization — only legal
/// under `firestore.rules` for a super-admin, and only ever injected from
/// the super-admin-gated `/organizations` route. Every other admin page
/// stays scoped to the caller's own org via the Cloud Functions it calls,
/// never a direct client query here.
final organizationsProvider = StreamProvider<List<Organization>>((ref) {
  return FirebaseFirestore.instance
      .collection('organizations')
      .orderBy('name')
      .snapshots()
      .map((snapshot) => snapshot.docs.map((doc) => Organization.fromFirestore(doc.id, doc.data())).toList());
});

// ownOrganizationProvider (this screen's own retention/CMEK/audit-logging/
// FHIR-export toggles all bind to it) moved to amdash_core's
// own_organization_service.dart once EMS and physician also needed to
// read fhirExportEnabled — still available here via the amdash_core
// import above, just no longer defined in this file.
