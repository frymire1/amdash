import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ems_location_service.dart';
import '../services/patient_service.dart';
import '../utils/geo.dart';
import 'patient_card.dart';

/// Mirrors `patient-list.component.ts`/`.html`: a filterable (by
/// destination hospital), optionally distance-sorted list of the org's
/// active patients.
class PatientList extends ConsumerStatefulWidget {
  const PatientList({required this.onSelected, super.key});

  final ValueChanged<Patient> onSelected;

  @override
  ConsumerState<PatientList> createState() => _PatientListState();
}

class _PatientListState extends ConsumerState<PatientList> {
  bool _filterOpen = false;
  bool _sortByDistance = false;
  // Always a concrete hospital once the lists load — there is no
  // "All destinations" option; a physician only cares about patients
  // inbound to one hospital at a time. Null only during the brief window
  // before the default is applied.
  String? _selectedDestination;

  // The destination filter defaults to the physician's own work location
  // (see build) — but only once, so a later manual choice sticks across
  // rebuilds.
  bool _appliedDefaultDestination = false;

  // Latches true the first time the (now guaranteed server-confirmed, see
  // physicianPatientsProvider) patients stream produces a value, and stays
  // true from then on — gates the loading spinner below.
  bool _loadedOnce = false;

  Hospital? _findHospital(List<Hospital> hospitals, String? name) {
    if (name == null) return null;
    for (final hospital in hospitals) {
      if (hospital.name == name) return hospital;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final patientsAsync = ref.watch(physicianPatientsProvider);
    if (patientsAsync.hasValue) _loadedOnce = true;
    final patients = patientsAsync.valueOrNull ?? const [];
    final hospitals = ref.watch(hospitalsProvider).valueOrNull ?? const [];
    final profile = ref.watch(userProfileProvider).valueOrNull;

    final destinationOptions = [for (final h in hospitals) h.name];

    // Default the filter to the physician's own hospital once both the
    // profile and hospital list have loaded — a physician only cares about
    // patients inbound to where they are. Falls back to the first hospital
    // if their work location isn't one of the destinations. Guarded so it
    // applies just once and never overrides a manual choice later.
    if (!_appliedDefaultDestination && destinationOptions.isNotEmpty && profile != null) {
      final workLocation = profile.workLocation;
      _selectedDestination = (workLocation != null && destinationOptions.contains(workLocation))
          ? workLocation
          : destinationOptions.first;
      _appliedDefaultDestination = true;
    }

    var filtered = _selectedDestination == null
        ? <Patient>[]
        : patients.where((p) => p.destination == _selectedDestination).toList();

    final myHospital = _sortByDistance ? _findHospital(hospitals, profile?.workLocation) : null;
    if (myHospital != null) {
      filtered = [...filtered]..sort((a, b) {
        final da = a.location == null
            ? double.infinity
            : distanceMeters(myHospital.latitude, myHospital.longitude, a.location!.latitude, a.location!.longitude);
        final db = b.location == null
            ? double.infinity
            : distanceMeters(myHospital.latitude, myHospital.longitude, b.location!.latitude, b.location!.longitude);
        return da.compareTo(db);
      });
    }

    // A destination is always selected now, so "active" means the physician
    // has moved off their own hospital or turned on distance sorting.
    final filterActive =
        _sortByDistance || (_selectedDestination != null && _selectedDestination != profile?.workLocation);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text('Patients', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                onPressed: () => setState(() => _filterOpen = !_filterOpen),
                icon: Icon(Icons.filter_list, color: filterActive ? AppColors.brand : null),
                tooltip: 'Filter',
              ),
            ],
          ),
        ),
        if (_selectedDestination != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Text(
              'Currently showing patients en route to $_selectedDestination',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
            ),
          ),
        if (_filterOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _selectedDestination,
                      decoration: const InputDecoration(labelText: 'Destination'),
                      items: [
                        for (final option in destinationOptions)
                          DropdownMenuItem(value: option, child: Text(option)),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _selectedDestination = value);
                      },
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _sortByDistance,
                      title: const Text('Sort by distance from my hospital'),
                      onChanged: (value) => setState(() => _sortByDistance = value ?? false),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: !_loadedOnce
              ? const Center(child: CircularProgressIndicator())
              : filtered.isEmpty
              ? Center(
                  child: Text(
                    patients.isEmpty ? 'No patients uploaded yet.' : 'No patients match this filter.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final patient = filtered[index];
                    final info = emsTrackingInfo(ref, patient.id);
                    // Straight-line (haversine) distance from the vehicle's
                    // last known fix to its destination hospital — pure math
                    // from data already streamed to the list, so unlike the
                    // road ETA in PatientViewer it costs no Directions API
                    // call and can show on every card without opening one.
                    final location = info.location;
                    final destination = _findHospital(hospitals, patient.destination);
                    final distanceToHospitalMeters =
                        (location?.latitude != null && location?.longitude != null && destination != null)
                            ? distanceMeters(
                                location!.latitude!, location.longitude!, destination.latitude, destination.longitude)
                            : null;
                    return PatientCard(
                      patient: patient,
                      trackingStatus: info.status,
                      distanceToHospitalMeters: distanceToHospitalMeters,
                      onTap: () => widget.onSelected(patient),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
