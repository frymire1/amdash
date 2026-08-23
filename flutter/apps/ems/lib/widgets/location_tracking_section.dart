import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../services/ems_tracking_service.dart';

/// The live location fetch/tracking-status UI for the patient upload form
/// — split out of `PatientUploadScreen` since it owns a fair amount of
/// self-contained async state (periodic geolocation polling, app-resume
/// rechecking) that's independent of the rest of the form's fields.
///
/// Reports its current values back up via [onChanged] whenever they change,
/// so the parent can include them when submitting — the parent doesn't
/// otherwise need to know how this section gets its data. There's nothing
/// to seed the very first frame with (e.g. when reopening an already-
/// created patient to edit it): no location is ever persisted on the
/// patient doc itself (see `patient_upload_service.dart`), so this section
/// always starts from scratch and lets its own live fetch — which always
/// runs on mount regardless — resolve the current position. On a create,
/// [LocationTrackingValue.latitude]/[longitude] end up used exactly once,
/// as the seed for this new patient's very first `patients/{id}/location/
/// current` fix (see `uploadPatientDocument`) — nowhere does this fetched
/// value get written on its own.
class LocationTrackingSection extends ConsumerStatefulWidget {
  const LocationTrackingSection({
    super.key,
    required this.patientId,
    required this.onChanged,
  });

  /// Null in create mode.
  final String? patientId;
  final ValueChanged<LocationTrackingValue> onChanged;

  @override
  ConsumerState<LocationTrackingSection> createState() => _LocationTrackingSectionState();
}

class LocationTrackingValue {
  const LocationTrackingValue({
    required this.latitude,
    required this.longitude,
    required this.liveTrackingEnabled,
    required this.hasLocationError,
  });

  final double? latitude;
  final double? longitude;
  final bool liveTrackingEnabled;

  /// True when the current position couldn't be fetched — most often
  /// because location permission is off. Lets the parent screen warn the
  /// user before they submit, rather than only finding out after the
  /// patient's already been saved.
  final bool hasLocationError;
}

class _LocationTrackingSectionState extends ConsumerState<LocationTrackingSection> with WidgetsBindingObserver {
  double? _latitude;
  double? _longitude;
  String? _locationError;
  bool _locationShared = false;
  bool _liveTrackingEnabled = true;
  bool _isFetchingLocation = false;
  Timer? _locationPollTimer;

  @override
  void initState() {
    super.initState();
    if (widget.patientId != null) {
      _liveTrackingEnabled = ref.read(emsTrackingProvider.notifier).isTracking(widget.patientId!);
    }
    // Mirror the initial (still-unresolved) state up immediately — the
    // parent's own copy shouldn't rely on guessing the same defaults this
    // widget uses, and the first live location fetch below can take up to
    // ~12s.
    _reportChange();

    // Runs for both create and edit — live tracking can be toggled on
    // while editing an already-uploaded patient too, so the toggle needs
    // to reflect real, current location availability there as well, not
    // just at creation time.
    WidgetsBinding.instance.addObserver(this);
    _useCurrentLocation();
    // A one-time check at load can't catch location being disabled *after*
    // the page opens — confirmed on web, where isLocationServiceEnabled()
    // is hardcoded to always return true (browsers don't expose that
    // separately from permission) and getServiceStatusStream() isn't
    // supported at all. Re-attempting the real fetch periodically is the
    // only reliable way to detect that on web, so the toggle stays in sync
    // with reality instead of only reflecting the state from the moment
    // the form opened. Paired with didChangeAppLifecycleState below for an
    // immediate recheck when the tab/app comes back into view, rather than
    // waiting out the interval — the common real case is backgrounding the
    // app, flipping location off in system settings, then returning.
    _locationPollTimer = Timer.periodic(const Duration(seconds: 15), (_) => _useCurrentLocation());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _useCurrentLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationPollTimer?.cancel();
    super.dispose();
  }

  void _reportChange() {
    widget.onChanged(
      LocationTrackingValue(
        latitude: _latitude,
        longitude: _longitude,
        liveTrackingEnabled: _liveTrackingEnabled,
        hasLocationError: _locationError != null,
      ),
    );
  }

  Future<void> _useCurrentLocation() async {
    // Guards against overlapping attempts — the 15s periodic timer below
    // could otherwise fire again while a slow fetch (up to the 12s timeout)
    // from the previous tick is still in flight, and an explicit Retry tap
    // could land mid-background-attempt too.
    if (_isFetchingLocation) return;
    setState(() => _isFetchingLocation = true);

    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      // Deliberately NOT passing `timeLimit` here: geolocator_web 4.1.4 has
      // a confirmed bug (html_geolocation_manager.dart) where it computes
      // the browser's timeout via `timeout?.inMicroseconds` but treats the
      // result as milliseconds — a 10-second Duration becomes an effective
      // ~2.78-HOUR browser-level timeout. This explicit `.timeout()` is a
      // Dart-level backstop that's independent of that bug — it forces
      // resolution one way or another regardless of what the browser is
      // doing internally.
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
        _locationShared = true;
        _locationError = null;
        _isFetchingLocation = false;
      });
      _reportChange();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _locationShared = false;
        _locationError = 'Could not get your current location. Please allow location access and try again.';
        // Without a real location, live tracking has nothing to send —
        // force it off and disable the toggle (see the SwitchListTile's
        // onChanged below) rather than letting the EMS worker turn on a
        // promise the app can't keep.
        _liveTrackingEnabled = false;
        _isFetchingLocation = false;
      });
      _reportChange();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _locationError != null
                  ? Text(_locationError!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                  : !_liveTrackingEnabled
                      ? const _LocationStatus(icon: Icons.location_off, text: 'Location sharing is off')
                      : _locationShared
                          ? const _LocationStatus(
                              icon: Icons.check_circle,
                              text: 'Tracking Active',
                              color: AppColors.success,
                            )
                          : const _LocationStatus(icon: Icons.location_searching, text: 'Locating…'),
            ),
            // Lets the EMS worker force a fresh attempt without reloading
            // the whole page — shown whenever we don't yet have a
            // confirmed fix (error, or still waiting). Disabled (with a
            // small spinner in place of the label) while a fetch — whether
            // this tap or the background 15s poll — is already in flight,
            // rather than leaving it tappable and silently piling up a
            // second overlapping attempt.
            if (_locationError != null || (_liveTrackingEnabled && !_locationShared))
              TextButton(
                onPressed: _isFetchingLocation ? null : _useCurrentLocation,
                child: _isFetchingLocation
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Retry'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Live-track this patient'),
          value: _liveTrackingEnabled,
          // Disabled (not just off) while location is unavailable — there's
          // nothing to send, so don't let the EMS worker toggle on a
          // promise the app can't keep.
          onChanged: _locationError != null
              ? null
              : (value) {
                  setState(() => _liveTrackingEnabled = value);
                  _reportChange();
                },
        ),
      ],
    );
  }
}

class _LocationStatus extends StatelessWidget {
  const _LocationStatus({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(color: color)),
      ],
    );
  }
}
