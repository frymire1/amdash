import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/ambulance_id_service.dart';
import '../services/ambulance_phone_service.dart';

/// EMS-only route tier, composed after `AppRouteGuard.redirect` in
/// router.dart — deliberately NOT folded into amdash_core's shared
/// `AppRouteGuard` (which stays app-agnostic; physician/admin never need
/// this at all). Mirrors `AppRouteGuard`'s own `requireWorkLocation` tier
/// in shape (block entry until a value is set, self-heal a stale-cache
/// flicker back to home), but gated on top by the org's own
/// `enableMultipleAmbulanceView` flag: an org that hasn't opted in sees
/// zero behavior change here at all, never even reaching the Ambulance ID
/// check.
///
/// The phone-number check only runs once an Ambulance ID is already
/// confirmed set — not just to mirror "one thing at a time," but so a
/// device that's never touched either provider never reads
/// ambulancePhoneProvider at all, keeping every existing "nothing set
/// yet" test/case from needing to know this field exists.
class AmbulanceIdGuard {
  const AmbulanceIdGuard._(); // coverage:ignore-line

  static String? redirect({
    required Ref ref,
    required GoRouterState state,
    String ambulanceIdPath = '/ambulance-id',
    String homePath = '/',
  }) {
    final orgState = ref.read(ownOrganizationProvider);
    if (orgState.isLoading) return null;
    final featureEnabled = orgState.valueOrNull?.enableMultipleAmbulanceView ?? false;
    if (!featureEnabled) return null;

    final idState = ref.read(ambulanceIdProvider);
    if (idState.isLoading) return null;
    final hasAmbulanceId = (idState.valueOrNull ?? '').isNotEmpty;
    if (!hasAmbulanceId) {
      return state.matchedLocation == ambulanceIdPath ? null : ambulanceIdPath;
    }

    final phoneState = ref.read(ambulancePhoneProvider);
    if (phoneState.isLoading) return null;
    final hasAmbulancePhone = (phoneState.valueOrNull ?? '').isNotEmpty;
    if (!hasAmbulancePhone) {
      return state.matchedLocation == ambulanceIdPath ? null : ambulanceIdPath;
    }

    // Self-heals a stale-cache flicker exactly like AppRouteGuard's own
    // requireWorkLocation tier does — a freshly (re)attached provider can
    // transiently emit a cached/stale value before the corrected one
    // arrives; without this, nothing would ever navigate back out of
    // ambulanceIdPath once both a real ID and phone number are confirmed set.
    if (state.matchedLocation == ambulanceIdPath) return homePath;
    return null;
  }
}
