import Flutter
import UIKit

final class SleepSensorsBridge {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "audio_dashcam/sleep_sensors",
      binaryMessenger: messenger
    )
    let instance = SleepSensorsBridge()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "sampleSleepSignals":
      result([
        "sampledAtMillis": Int(Date().timeIntervalSince1970 * 1000),
        "motionAvailable": false,
        "ambientLightAvailable": false,
        "screenBrightness": Double(UIScreen.main.brightness)
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
