// Native side of the audio_dashcam/device_storage MethodChannel (iOS): reports
// free disk space so the rolling buffer can honor its "space permitting" floor.
import Flutter
import UIKit

final class DeviceStorageBridge {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "audio_dashcam/device_storage",
      binaryMessenger: messenger
    )
    let instance = DeviceStorageBridge()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "freeBytes":
      guard
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String,
        !path.isEmpty
      else {
        result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        return
      }
      let url = URL(fileURLWithPath: path)
      do {
        // volumeAvailableCapacityForImportantUsage reflects what iOS will
        // actually let the app write (purgeable space included).
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
          result(Int64(capacity))
          return
        }
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
        result((attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? nil)
      } catch {
        result(FlutterError(code: "statfs_failed", message: error.localizedDescription, details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
