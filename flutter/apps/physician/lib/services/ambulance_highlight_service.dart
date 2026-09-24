import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks which ambulance (if any) should be visually highlighted across
/// [AmbulanceList]'s cards and [MultipleAmbulanceView]'s map markers — the
/// two are siblings under `MainViewScreen`, not parent/child, so this is
/// the simplest shared seam between them (same shape as
/// `directionsCacheProvider`'s own cross-widget cache).
///
/// Two independent inputs feed one effective value: [hoveredId] is a
/// transient, desktop-mouse-only signal — there is no touch equivalent,
/// and `google_maps_flutter`'s own `Marker` type exposes no `onHover`
/// callback at all (confirmed against the platform interface source), so
/// a map marker can only ever drive [selectedId], never [hoveredId].
/// [selectedId] latches until a different ambulance is selected (by a
/// card tap/click or a marker tap), so tapping still works as a highlight
/// on touch devices where hover never fires at all.
class AmbulanceHighlightState {
  const AmbulanceHighlightState({this.selectedId, this.hoveredId});

  final String? selectedId;
  final String? hoveredId;

  /// What should actually render as highlighted right now — an active
  /// hover always wins over a latched selection, matching how a mouse
  /// physically hovering a different card/marker should visually "preview"
  /// it, without losing track of the last real selection underneath.
  String? get effectiveId => hoveredId ?? selectedId;
}

class AmbulanceHighlightController extends Notifier<AmbulanceHighlightState> {
  @override
  AmbulanceHighlightState build() => const AmbulanceHighlightState();

  void select(String? ambulanceId) {
    state = AmbulanceHighlightState(selectedId: ambulanceId, hoveredId: state.hoveredId);
  }

  void hover(String? ambulanceId) {
    state = AmbulanceHighlightState(selectedId: state.selectedId, hoveredId: ambulanceId);
  }
}

final ambulanceHighlightProvider =
    NotifierProvider<AmbulanceHighlightController, AmbulanceHighlightState>(AmbulanceHighlightController.new);
