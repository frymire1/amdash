import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ambulance_highlight_service.dart';
import '../services/ambulance_location_service.dart';
import 'ambulance_card.dart';
import 'multiple_ambulance_view.dart' show AmbulanceViewFilter;

/// `MultipleAmbulanceView`'s sidebar counterpart — mirrors `PatientList`'s
/// shape (loading/empty states, a scrollable card list), but every known
/// ambulance matching [filter], whether or not it currently has an active
/// patient, rather than an org's active patients. Deliberately no
/// `onSelected` callback the way `PatientList` has: tapping/hovering a
/// card here only ever highlights the matching map marker (via
/// `ambulanceHighlightProvider`), it never navigates anywhere — there is
/// no per-ambulance detail screen, the map itself is the detail view.
class AmbulanceList extends ConsumerWidget {
  const AmbulanceList({required this.filter, super.key});

  final AmbulanceViewFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ambulanceLocationProvider);
    final highlightedId = ref.watch(ambulanceHighlightProvider).effectiveId;
    final highlight = ref.read(ambulanceHighlightProvider.notifier);

    // Sorted by ambulanceId for a stable, predictable order — there's no
    // natural "distance" concept the way PatientList's own optional sort
    // has (that's measured from a physician's own hospital to a patient's
    // vehicle; a fleet-wide list has no single reference point to sort
    // against).
    final entries = state.info.values.where((info) => filter == AmbulanceViewFilter.all || !info.location.isTransporting).toList()
      ..sort((a, b) => a.location.ambulanceId.compareTo(b.location.ambulanceId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Text('Ambulances', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: !state.hasLoadedOnce
              ? const Center(child: CircularProgressIndicator())
              : entries.isEmpty
              ? EmptyState(
                  title: filter == AmbulanceViewFilter.emptyOnly
                      ? 'No empty ambulances right now'
                      : 'No ambulances to show',
                  subtitle: 'Ambulance locations appear here once a crew signs in and identifies their vehicle.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final info = entries[index];
                    final ambulanceId = info.location.ambulanceId;
                    return AmbulanceCard(
                      info: info,
                      highlighted: highlightedId == ambulanceId,
                      onTap: () => highlight.select(ambulanceId),
                      onHoverChanged: (isHovering) => highlight.hover(isHovering ? ambulanceId : null),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
