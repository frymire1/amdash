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

class EmsLocationState {
  const EmsLocationState({this.activeLocations = const {}, this.trackedPatientIds = const {}});

  final Map<String, ActiveLocation> activeLocations;
  final Set<String> trackedPatientIds;
}

/// Mirrors `apps/physician/src/app/services/ems-location.service.ts`:
/// subscribes to `emsLocations` (organizationId + active==true), carries
/// each patient's previous fix forward onto the next one (so
/// `PatientViewer` can lerp the marker between them over the real elapsed
/// wall-clock gap), and sweeps for staleness every 5s independent of
/// whether new Firestore snapshots arrive at all.
class EmsLocationController extends Notifier<EmsLocationState> {
  StreamSubscription<QuerySnapshot<Map<String, Object?>>>? _subscription;
  Timer? _staleTimer;
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
    state = const EmsLocationState();

    if (organizationId == null) return;

    _subscription = FirebaseFirestore.instance
        .collection('emsLocations')
        .where('organizationId', isEqualTo: organizationId)
        .where('active', isEqualTo: true)
        .snapshots()
        .listen(_onSnapshot);

    _staleTimer = Timer.periodic(const Duration(seconds: 5), (_) => _recomputeFresh());
  }

  void _onSnapshot(QuerySnapshot<Map<String, Object?>> snapshot) {
    final previous = _latest;
    final next = <String, ActiveLocation>{};

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final updatedAt = data['updatedAt'] as Timestamp?;
      if (updatedAt == null) continue;

      final patientId = doc.id;
      final previousFix = previous[patientId];
      next[patientId] = ActiveLocation(
        patientId: patientId,
        updatedAtMs: updatedAt.millisecondsSinceEpoch,
        latitude: (data['latitude'] as num?)?.toDouble(),
        longitude: (data['longitude'] as num?)?.toDouble(),
        previousLatitude: previousFix?.latitude,
        previousLongitude: previousFix?.longitude,
        previousUpdatedAtMs: previousFix?.updatedAtMs,
      );
    }

    _latest = next;
    _recomputeFresh();
  }

  void _recomputeFresh() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final fresh = <String, ActiveLocation>{
      for (final entry in _latest.entries)
        if (nowMs - entry.value.updatedAtMs <= _staleAfterMs) entry.key: entry.value,
    };
    state = EmsLocationState(activeLocations: fresh, trackedPatientIds: fresh.keys.toSet());
  }
}

final emsLocationProvider = NotifierProvider<EmsLocationController, EmsLocationState>(
  EmsLocationController.new,
);

bool isPatientTracked(WidgetRef ref, String patientId) {
  return ref.watch(emsLocationProvider.select((s) => s.trackedPatientIds.contains(patientId)));
}

ActiveLocation? patientActiveLocation(WidgetRef ref, String patientId) {
  return ref.watch(emsLocationProvider.select((s) => s.activeLocations[patientId]));
}
