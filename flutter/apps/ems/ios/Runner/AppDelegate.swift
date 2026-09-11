import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let locationAlwaysUpgradeHandler = LocationAlwaysUpgradeHandler()

  // No override of application(_:didFinishLaunchingWithOptions:) needed —
  // there used to be one here that manually set
  // UNUserNotificationCenter.current().delegate = self, on the assumption
  // that flutter_foreground_task's own background-task notification
  // needed it to display. Removed: verified directly against that
  // plugin's real source (ios/Classes/SwiftFlutterForegroundTaskPlugin.swift)
  // that it registers its own UNUserNotificationCenterDelegate handling
  // via registrar.addApplicationDelegate(instance) — Flutter's standard
  // plugin-delegate mechanism, the exact same one firebase_messaging's
  // own iOS plugin uses for the identical purpose — so nothing here ever
  // needed this app to claim that delegate manually. That original line
  // was also never actually verified to work (this repo has no Mac/Xcode
  // to build and run it on) — it directly claimed a single-owner OS
  // property (UNUserNotificationCenter.current().delegate) that
  // firebase_messaging's own plugin separately needs for itself, found
  // while chasing a real device's registration silently and consistently
  // failing with [firebase_messaging/apns-token-not-set] no matter how
  // long getToken() was retried (see ems_alert_service.dart's own
  // _getTokenWaitingForApns).
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // See LocationAlwaysUpgradeHandler's own doc comment: works around a
    // confirmed geolocator_apple limitation by talking to CoreLocation
    // directly instead. A plain method channel off a throwaway plugin key
    // (rather than a real Flutter plugin) since this app is the only
    // caller — same technique GeneratedPluginRegistrant's own generated
    // plugins use to reach the engine's binary messenger.
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AmDashLocationAlwaysUpgrade")
    let channel = FlutterMethodChannel(
      name: "com.amdash.ems/location_always_upgrade",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "requestAlwaysUpgrade" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.locationAlwaysUpgradeHandler.requestUpgrade(result: result)
    }
  }
}
