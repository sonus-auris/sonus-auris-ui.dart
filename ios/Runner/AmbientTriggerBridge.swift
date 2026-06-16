import Flutter
import Foundation
import Network

/// Native side of `audio_dashcam/ambient_triggers` for OS-level context changes
/// iOS exposes to apps. Arbitrary Bluetooth connection wakeups are not available
/// on iOS without a declared CoreBluetooth service relationship.
final class AmbientTriggerBridge {
  private static let channelName = "audio_dashcam/ambient_triggers"
  private static var instance: AmbientTriggerBridge?

  static func register(messenger: FlutterBinaryMessenger) {
    let bridge = AmbientTriggerBridge(messenger: messenger)
    instance = bridge
    bridge.channel.setMethodCallHandler { call, result in
      bridge.handle(call, result: result)
    }
  }

  private let channel: FlutterMethodChannel
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "ambient-trigger-monitor")
  private var started = false
  private var lastSignature: String?

  private init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startMonitoring":
      startMonitoring()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startMonitoring() {
    guard !started else { return }
    started = true
    monitor.pathUpdateHandler = { [weak self] path in
      self?.handlePath(path)
    }
    monitor.start(queue: queue)
  }

  private func handlePath(_ path: NWPath) {
    let signature = [
      path.status == .satisfied ? "online" : "offline",
      path.usesInterfaceType(.wifi) ? "wifi" : nil,
      path.usesInterfaceType(.cellular) ? "cellular" : nil,
      path.usesInterfaceType(.wiredEthernet) ? "ethernet" : nil,
    ].compactMap { $0 }.joined(separator: "+")
    if lastSignature == nil {
      lastSignature = signature
      return
    }
    guard signature != lastSignature else { return }
    lastSignature = signature
    let label: String
    if path.usesInterfaceType(.wifi) {
      label = "Wi-Fi changed"
    } else if path.usesInterfaceType(.cellular) {
      label = "Cellular connection changed"
    } else {
      label = "Network changed"
    }
    let payload: [String: Any] = [
      "kind": "connectivity",
      "label": label,
      "detail": signature,
      "occurredAtMillis": Int64(Date().timeIntervalSince1970 * 1000),
    ]
    DispatchQueue.main.async { [channel] in
      channel.invokeMethod("trigger", arguments: payload)
    }
  }
}
