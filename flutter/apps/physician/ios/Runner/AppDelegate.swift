import Flutter
import GoogleMaps
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Google Maps SDK for iOS. Currently unrestricted in Google Cloud
    // Console — consider adding a bundle ID restriction
    // (com.amdash.physician) later so the key can't be lifted from the
    // compiled app and used elsewhere.
    GMSServices.provideAPIKey("AIzaSyD3rsgPSJGe5-YGt1F8HF9lxiSMfhTPbu8")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
