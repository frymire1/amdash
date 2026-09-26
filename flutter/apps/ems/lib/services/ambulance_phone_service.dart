import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ambulancePhonePrefsKey = 'amdash-ems-ambulance-phone';

/// Persists the best phone number to reach this vehicle's crew, on THIS
/// device via SharedPreferences — same rationale and shape as
/// AmbulanceIdService (identifies the vehicle, not the paramedic), kept as
/// its own service rather than folded into AmbulanceIdService:
/// ambulanceIdProvider already has other consumers (AmbulanceIdGuard, the
/// router) that only care about the ID, never the phone number.
class AmbulancePhoneService {
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_ambulancePhonePrefsKey);
  }

  Future<void> save(String phoneNumber) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ambulancePhonePrefsKey, phoneNumber);
  }
}

final ambulancePhoneServiceProvider = Provider<AmbulancePhoneService>((ref) => AmbulancePhoneService());

/// The device's currently-saved callback phone number, or null if none has
/// been set yet. Not auto-refreshing on save — AmbulanceIdScreen explicitly
/// calls `ref.invalidate(ambulancePhoneProvider)` after a successful save,
/// same as ambulanceIdProvider's own identical shape.
final ambulancePhoneProvider = FutureProvider<String?>((ref) => ref.watch(ambulancePhoneServiceProvider).read());
