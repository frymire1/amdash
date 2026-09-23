import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ambulanceIdPrefsKey = 'amdash-ems-ambulance-id';

/// Persists the physical vehicle's Ambulance ID on THIS device via
/// SharedPreferences — deliberately not on the signed-in user's Firestore
/// profile: it identifies the vehicle, not the paramedic, so a different
/// medic signing into the same device should never see the Ambulance ID
/// prompt again, while the same medic signing into a different device
/// should. Mirrors EmsTrackingController's own SharedPreferences-backed
/// tracking-resume state (ems_tracking_service.dart) — same package, same
/// lazily-cached-instance shape, just a single string instead of a set of
/// tracked patientIds.
class AmbulanceIdService {
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_ambulanceIdPrefsKey);
  }

  Future<void> save(String ambulanceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ambulanceIdPrefsKey, ambulanceId);
  }
}

final ambulanceIdServiceProvider = Provider<AmbulanceIdService>((ref) => AmbulanceIdService());

/// The device's currently-saved Ambulance ID, or null if none has been set
/// yet. Not auto-refreshing on save — AmbulanceIdScreen explicitly calls
/// `ref.invalidate(ambulanceIdProvider)` after a successful save, same as
/// any other one-shot FutureProvider in this codebase (e.g. amdash_core's
/// own mfaEnrolledFactorsProvider).
final ambulanceIdProvider = FutureProvider<String?>((ref) => ref.watch(ambulanceIdServiceProvider).read());
