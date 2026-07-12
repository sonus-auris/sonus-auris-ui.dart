// iOS app delegate: registers plugins/bridges and routes scheduled-recording local notifications through the app so consent taps foreground it.
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Route scheduled-recording local notifications through the app so a tap on
    // the "scheduled recording is starting" consent prompt foregrounds the app
    // and flutter_local_notifications can deliver the launch/response payload.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IcloudBridge") {
      IcloudBridge.register(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SleepSensorsBridge") {
      SleepSensorsBridge.register(messenger: registrar.messenger())
    }
    if #available(iOS 15.0, *),
       let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShazamBridge") {
      ShazamBridge.register(messenger: registrar.messenger())
    }
  }
}
