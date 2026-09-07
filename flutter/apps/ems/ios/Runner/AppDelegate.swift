import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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
  }
}
