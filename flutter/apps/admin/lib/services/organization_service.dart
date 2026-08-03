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

/// Mirrors `OrganizationSettingsComponent`'s direct live listener on
/// `organizations/{callerOrgId}` — legal per `firestore.rules`'
/// `sameOrgAsCaller(orgId)` `get`, unlike [organizationsProvider] above.
/// The retention toggle binds to this live value directly rather than
/// local optimistic state: on success the listener reflects the confirmed
/// write on its own; on failure there's nothing to roll back.
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
