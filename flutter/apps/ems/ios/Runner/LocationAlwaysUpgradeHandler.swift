import CoreLocation
import Flutter

/// Works around a confirmed limitation in geolocator_apple 2.3.14 (also
/// reported upstream — Baseflow/flutter-geolocator#1223 and #889): its
/// native `PermissionHandler.m` immediately echoes back
/// `CLLocationManager.authorizationStatus` without ever calling
/// `requestAlwaysAuthorization()` whenever that status is already
/// determined — which, by construction, it always is by the time this app
/// tries to escalate a "While Using" grant to "Always" (see
/// ems_tracking_service.dart's own `_ensurePermissions` comment for the
/// full citation). So `Geolocator.requestPermission()` can never trigger
/// CoreLocation's "Change to Always Allow" system alert on a real device,
/// no matter how many times it's called.
///
/// This talks to `CLLocationManager` directly instead — the same
/// CoreLocation API geolocator_apple itself would call if its own guard
/// didn't block it — via a small platform channel
/// (`com.amdash.ems/location_always_upgrade`, wired up in
/// `AppDelegate.didInitializeImplicitFlutterEngine`) rather than a full
/// plugin, since this app is the only caller.
///
/// Not yet buildable/verifiable from this Windows machine (Xcode is
/// Mac-only) — wired now so it's ready whenever a Mac/CI picks this app up
/// (same status as the Info.plist keys it depends on).
class LocationAlwaysUpgradeHandler: NSObject, CLLocationManagerDelegate {
  private let locationManager = CLLocationManager()
  private var pendingResult: FlutterResult?

  override init() {
    super.init()
    locationManager.delegate = self
  }

  func requestUpgrade(result: @escaping FlutterResult) {
    if pendingResult != nil {
      // Mirrors geolocator_apple's own PermissionHandler.m behavior for an
      // overlapping request — this app never actually calls
      // requestUpgrade() concurrently (there's only ever one
      // startTracking()/_ensurePermissions() in flight per patient at a
      // time), but this guard keeps a stray second call from silently
      // dropping the FIRST caller's result instead of ever resolving it.
      result(FlutterError(
        code: "IN_PROGRESS",
        message: "An always-upgrade request is already running.",
        details: nil
      ))
      return
    }

    pendingResult = result
    locationManager.requestAlwaysAuthorization()
  }

  // iOS 14+ delegate callback (this app's deployment target is 15.0 — see
  // project.pbxproj — so no availability guard/legacy
  // locationManager(_:didChangeAuthorization:) fallback is needed).
  //
  // Fires once CoreLocation is done reacting to requestAlwaysAuthorization()
  // — including the no-op case where the user already answered the
  // always-upgrade prompt once before (same "answered once, stays
  // answered" rule as every other iOS permission alert): this callback
  // still fires immediately with the unchanged status, so pendingResult
  // never hangs waiting on an alert that was never going to show.
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard let result = pendingResult else { return }
    pendingResult = nil
    // The Dart side doesn't need to interpret this beyond "the call
    // completed" — emsTrackingHealthProvider's own next poll re-reads the
    // real status via Geolocator.checkPermission() regardless (see
    // evaluateHealth), so this just needs to unblock that read rather than
    // duplicate it.
    result(manager.authorizationStatus.rawValue)
  }
}
