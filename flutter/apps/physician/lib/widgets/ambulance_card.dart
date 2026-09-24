import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';

import '../services/ambulance_location_service.dart';

/// A clickable/hoverable ambulance summary card — [AmbulanceList]'s
/// counterpart to `PatientCard`, but keyed by `ambulanceId` and with no
/// per-item detail screen to navigate to (see `MultipleAmbulanceView`'s
/// own doc comment): tapping or hovering this card only ever highlights
/// the matching map marker, via [onHoverChanged]/[onTap] driving the
/// shared `ambulanceHighlightProvider`, not a navigation callback.
class AmbulanceCard extends StatelessWidget {
  const AmbulanceCard({
    required this.info,
    required this.highlighted,
    required this.onTap,
    required this.onHoverChanged,
    super.key,
  });

  final AmbulanceTrackingInfo info;
  final bool highlighted;
  final VoidCallback onTap;
  final ValueChanged<bool> onHoverChanged;

  @override
  Widget build(BuildContext context) {
    final location = info.location;
    return MouseRegion(
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        // A visibly distinct border, not just a background tint — reads
        // clearly against both light and dark themes, same reasoning as
        // the live map's own AppColors.trackingAccent border
        // (patient_viewer.dart's mapBox).
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: highlighted ? const BorderSide(color: AppColors.trackingAccent, width: 2) : BorderSide.none,
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        location.ambulanceId,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                    ),
                    _statusPill(info),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${location.latitude.toStringAsFixed(4)}, ${location.longitude.toStringAsFixed(4)}',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusPill(AmbulanceTrackingInfo info) {
    if (info.status == AmbulanceStatus.stale) {
      return const StatusPill(kind: StatusPillKind.warning, label: 'Lost Connection');
    }
    return info.location.isTransporting
        ? const StatusPill(kind: StatusPillKind.active, label: 'Transporting', pulsing: true)
        : const StatusPill(kind: StatusPillKind.neutral, label: 'Empty');
  }
}
