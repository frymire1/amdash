import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // flutter_foreground_task's own background-task notification needs
    // this delegate to actually display. GeneratedPluginRegistrant (see
    // didInitializeImplicitFlutterEngine below) already handles this
    // plugin's registration under this newer implicit-engine template, so
    // no manual registerPlugins() dance is needed here — unlike the
    // plugin's own README, which documents the older explicit-engine
    // pattern. Not yet buildable/verifiable from this Windows machine
    // (Xcode is Mac-only).
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
