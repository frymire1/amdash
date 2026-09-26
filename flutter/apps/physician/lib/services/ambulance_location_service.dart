import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/active_ambulance_location.dart';

/// EMS publishes an identified ambulance's own location every 60s while
/// idle (15s while actively transporting a patient) — see
/// `ems_tracking_service.dart`'s own `_idleAmbulancePublishInterval`. 2.5x
/// the idle cadence: generous enough that a single slow idle tick never
/// flickers a marker stale, while a genuinely gone-quiet ambulance still
/// reads as stale well before looking suspiciously frozen. A separate
/// constant from `EmsLocationController`'s own `_staleAfterMs` — the two
/// features publish on entirely different cadences.
const ambulanceStaleAfterMs = 150000;

enum AmbulanceStatus { active, stale }

class AmbulanceTrackingInfo {
  const AmbulanceTrackingInfo({required this.status, required this.location});

  final AmbulanceStatus status;
  final ActiveAmbulanceLocation location;
}

class AmbulanceLocationState {
  const AmbulanceLocationState({this.info = const {}, this.hasLoadedOnce = false});

  final Map<String, AmbulanceTrackingInfo> info;

  /// Whether the first Firestore snapshot (or the determination that
  /// there's no org/flag to query at all) has been received.
  final bool hasLoadedOnce;
}

/// Physician's fleet-wide counterpart to `EmsLocationController` — same
/// carried-forward-state/staleness-sweep shape, but subscribing to the
/// flat, top-level `ambulanceLocations` collection (a plain
/// organizationId-scoped query, not a `collectionGroup` — see
/// `firestore.rules`' own comment on why that distinction matters here)
/// instead of patients' per-document `location` subcollection, and with no
/// glide animation to drive (see `ActiveAmbulanceLocation`'s own doc
/// comment).
///
/// Only ever subscribes at all when the org has opted into
/// `enableMultipleAmbulanceView` — reading straight off `ownOrganizationProvider`
/// (whose own `id` field is the organization id, so no separate
/// `userProfileProvider` read is needed) avoids a guaranteed
/// permission-denied stream error against `firestore.rules`' own re-check
/// of that same flag otherwise.
class AmbulanceLocationController extends Notifier<AmbulanceLocationState> {
  StreamSubscription<QuerySnapshot<Map<String, Object?>>>? _subscription;
  Timer? _staleTimer;

  // Every fix ever seen this session, keyed by ambulanceId — same
  // never-pruned-just-because-it-dropped-out-of-the-query rationale as
  // EmsLocationController's own _latest map.
  Map<String, ActiveAmbulanceLocation> _latest = {};

  @override
  AmbulanceLocationState build() {
    // Same "return the correct initial state from build() itself, only
    // ref.listen for genuinely later changes" shape as
    // EmsLocationController.build() — see that method's own comment for
    // the confirmed bug this avoids.
    ref.listen<AsyncValue<Organization?>>(ownOrganizationProvider, (previous, next) => _resubscribe());

    ref.onDispose(() {
      _subscription?.cancel();
      _staleTimer?.cancel();
    });

    return _rebuild();
  }

  void _resubscribe() {
    state = _rebuild();
  }

  String? get _effectiveOrganizationId {
    final organization = ref.read(ownOrganizationProvider).valueOrNull;
    return organization?.enableMultipleAmbulanceView == true ? organization!.id : null;
  }

  AmbulanceLocationState _rebuild() {
    _subscription?.cancel();
    _staleTimer?.cancel();
    _latest = {};

    final organizationId = _effectiveOrganizationId;
    if (organizationId == null) {
      // No org, or the org hasn't opted in — that *is* the answer, not
      // still-loading.
      return const AmbulanceLocationState(hasLoadedOnce: true);
    }

    // A plain, non-collection-group query — ambulanceLocations/{docId} is
    // its own flat top-level collection, not a per-patient subcollection
    // (see the plan's own data-model note on why: there's no parent
    // "ambulance" document the way patients/{id} exists for a patient's
    // own location).
    //
    // onError swallows a query failure (permission/index issues, mainly)
    // rather than leaving it as an unhandled stream error — same
    // reasoning as EmsLocationController's identical onError.
    _subscription = ref
        .read(firestoreProvider)
        .collection('ambulanceLocations')
        .where('organizationId', isEqualTo: organizationId)
        .snapshots()
        .listen(_onSnapshot, onError: (_) {});

    _staleTimer = Timer.periodic(const Duration(seconds: 5), (_) => _recompute());
    return const AmbulanceLocationState();
  }

  void _onSnapshot(QuerySnapshot<Map<String, Object?>> snapshot) {
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final updatedAt = data['updatedAt'] as Timestamp?;
      final ambulanceId = data['ambulanceId'] as String?;
      final latitude = (data['latitude'] as num?)?.toDouble();
      final longitude = (data['longitude'] as num?)?.toDouble();
      if (updatedAt == null || ambulanceId == null || latitude == null || longitude == null) continue;

      _latest[ambulanceId] = ActiveAmbulanceLocation(
        ambulanceId: ambulanceId,
        latitude: latitude,
        longitude: longitude,
        isTransporting: data['isTransporting'] as bool? ?? false,
        updatedAtMs: updatedAt.millisecondsSinceEpoch,
        // Defensive fallback for any doc written before this field
        // existed — the backend has required it on every publish since,
        // so in practice this only matters for pre-migration data.
        phoneNumber: (data['phoneNumber'] as String?) ?? '',
      );
    }
    // Deliberately not removing entries whose doc is missing from this
    // snapshot — same "was tracked, now stale" preservation as
    // EmsLocationController's own _onSnapshot.

    _recompute();
  }

  void _recompute() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final info = <String, AmbulanceTrackingInfo>{
      for (final entry in _latest.entries)
        entry.key: AmbulanceTrackingInfo(
          status: nowMs - entry.value.updatedAtMs <= ambulanceStaleAfterMs
              ? AmbulanceStatus.active
              : AmbulanceStatus.stale,
          location: entry.value,
        ),
    };
    state = AmbulanceLocationState(info: info, hasLoadedOnce: true);
  }
}

final ambulanceLocationProvider = NotifierProvider<AmbulanceLocationController, AmbulanceLocationState>(
  AmbulanceLocationController.new,
);
