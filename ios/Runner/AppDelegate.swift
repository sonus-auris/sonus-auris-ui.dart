import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    RecordingScheduleBridge.registerBackgroundTaskIfNeeded()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IcloudBridge") {
      IcloudBridge.register(messenger: registrar.messenger())
    }
    if #available(iOS 15.0, *),
       let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShazamBridge") {
      ShazamBridge.register(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RecordingScheduleBridge") {
      RecordingScheduleBridge.register(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AmbientTriggerBridge") {
      AmbientTriggerBridge.register(messenger: registrar.messenger())
    }
  }
}
