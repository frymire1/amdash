import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/active_location.dart';

/// EMS publishes a fix every 15s; if a device stops publishing without an
/// explicit stop signal (reload, tab close, network loss), Firestore stays
/// stuck at `active: true` forever — anything older than this is treated
/// as stale. Mirrors `ems-location.service.ts`'s `STALE_AFTER_MS`.
const _staleAfterMs = 35000;

/// One property driving every "is this patient being tracked" decision
/// across the app (the patient list's status badge, `PatientViewer`'s map) —
/// replacing several rounds of ad hoc, per-widget booleans that each had to
/// rediscover the same distinctions.
enum EmsTrackingStatus {
  /// Haven't received the first Firestore snapshot for this org yet — not
  /// the same as [noData]: don't treat "don't know yet" as "confirmed empty".
  loading,

  /// Snapshot(s) received; this patient has never had a location recorded.
  noData,

  /// A location is known, but it's older than [_staleAfterMs] — EMS likely
  /// went away without an explicit stop signal.
  stale,

  /// A location is known and within the freshness window.
  active,
}

class EmsTrackingInfo {
  const EmsTrackingInfo({required this.status, this.location});

  final EmsTrackingStatus status;

  /// The last known fix, if one has ever been recorded — populated for
  /// [EmsTrackingStatus.stale] and [EmsTrackingStatus.active] alike, so
  /// consumers can keep showing a patient's last known position/route
  /// while stale instead of losing it.
  final ActiveLocation? location;
}

class EmsLocationState {
  const EmsLocationState({this.info = const {}, this.hasLoadedOnce = false});

  final Map<String, EmsTrackingInfo> info;

  /// Whether the first Firestore snapshot (or the determination that there's
  /// no org to query at all) has been received — see [EmsTrackingStatus.loading].
  final bool hasLoadedOnce;
}

/// Mirrors `apps/physician/src/app/services/ems-location.service.ts`:
/// subscribes to every patient's `location` subcollection org-wide via a
/// `collectionGroup` query (organizationId + active==true), carries each
/// patient's previous fix forward onto the next one (so `PatientViewer`
/// can lerp the marker between them over the real elapsed wall-clock gap),
/// and sweeps for staleness every 5s independent of whether new Firestore
/// snapshots arrive at all.
class EmsLocationController extends Notifier<EmsLocationState> {
  StreamSubscription<QuerySnapshot<Map<String, Object?>>>? _subscription;
  Timer? _staleTimer;

  // Every fix ever seen this session, keyed by patientId — deliberately
  // never pruned just because a patient drops out of the live query
  // (explicit stop, or simply going stale) so a last-known position/route
  // is always available. Firestore's own `where('active', ...)` filter, not
  // this map, is what limits how much this can grow in practice.
  Map<String, ActiveLocation> _latest = {};

  @override
  EmsLocationState build() {
    ref.listen<AsyncValue<UserProfile?>>(
      userProfileProvider,
      (previous, next) => _resubscribe(next.valueOrNull?.organizationId),
      fireImmediately: true,
    );

    ref.onDispose(() {
      _subscription?.cancel();
      _staleTimer?.cancel();
    });

    return const EmsLocationState();
  }

  void _resubscribe(String? organizationId) {
    _subscription?.cancel();
    _staleTimer?.cancel();
    _latest = {};

    if (organizationId == null) {
      // No org to query — that *is* the answer, not still-loading.
      state = const EmsLocationState(hasLoadedOnce: true);
      return;
    }

    state = const EmsLocationState();

    // A collection group query — patients/{patientId}/location/current is
    // a subcollection, not its own top-level collection (see
    // functions/src/shared.ts's patientLocationRef for why), so this reads
    // every patient's location subdocument across the org in one query
    // rather than one listener per patient.
    _subscription = FirebaseFirestore.instance
        .collectionGroup('location')
        .where('organizationId', isEqualTo: organizationId)
        .where('active', isEqualTo: true)
        .snapshots()
        .listen(_onSnapshot);

    _staleTimer = Timer.periodic(const Duration(seconds: 5), (_) => _recompute());
  }

  void _onSnapshot(QuerySnapshot<Map<String, Object?>> snapshot) {
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final updatedAt = data['updatedAt'] as Timestamp?;
      // doc.id is always 'current' here, not the patient id (every
      // patient's location subdocument shares that same fixed id) — the
      // actual patient id has to come from the document's own field.
      final patientId = data['patientId'] as String?;
      if (updatedAt == null || patientId == null) continue;

      final previousFix = _latest[patientId];
      _latest[patientId] = ActiveLocation(
        patientId: patientId,
        updatedAtMs: updatedAt.millisecondsSinceEpoch,
        latitude: (data['latitude'] as num?)?.toDouble(),
        longitude: (data['longitude'] as num?)?.toDouble(),
        previousLatitude: previousFix?.latitude,
        previousLongitude: previousFix?.longitude,
        previousUpdatedAtMs: previousFix?.updatedAtMs,
      );
    }
    // Deliberately not removing entries whose doc is missing from this
    // snapshot (explicit stop, or aged out of the `active == true` query) —
    // that's exactly the "was tracked, now stale/stopped" case this state
    // model exists to represent, not something to silently forget.

    _recompute();
  }

  void _recompute() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final info = <String, EmsTrackingInfo>{
      for (final entry in _latest.entries)
        entry.key: EmsTrackingInfo(
          status: nowMs - entry.value.updatedAtMs <= _staleAfterMs
              ? EmsTrackingStatus.active
              : EmsTrackingStatus.stale,
          location: entry.value,
        ),
    };
    state = EmsLocationState(info: info, hasLoadedOnce: true);
  }
}

final emsLocationProvider = NotifierProvider<EmsLocationController, EmsLocationState>(
  EmsLocationController.new,
);

EmsTrackingInfo emsTrackingInfo(WidgetRef ref, String? patientId) {
  if (patientId == null) return const EmsTrackingInfo(status: EmsTrackingStatus.noData);
  final state = ref.watch(emsLocationProvider);
  final info = state.info[patientId];
  if (info != null) return info;
  return EmsTrackingInfo(status: state.hasLoadedOnce ? EmsTrackingStatus.noData : EmsTrackingStatus.loading);
}
