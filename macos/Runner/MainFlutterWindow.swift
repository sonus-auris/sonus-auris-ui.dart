import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    MacIcloudBridge.register(
      messenger: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }
}

/// macOS side of the same channel used by the iOS iCloud bridge. Files are
/// decrypted by Dart on-device, staged locally, and then handed to the shared
/// Sonus Auris iCloud Documents container.
private final class MacIcloudBridge {
  private let fileManager = FileManager.default

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "audio_dashcam/icloud",
      binaryMessenger: messenger
    )
    let instance = MacIcloudBridge()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private func ubiquityContainerURL() -> URL? {
    fileManager.url(forUbiquityContainerIdentifier: "iCloud.com.ores.audioDashcam")
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(
        fileManager.ubiquityIdentityToken != nil &&
          ubiquityContainerURL() != nil
      )
    case "importSegment":
      guard
        let arguments = call.arguments as? [String: Any],
        let destinationKey = arguments["destinationKey"] as? String,
        let payload = arguments["bytes"] as? FlutterStandardTypedData
      else {
        result(
          FlutterError(
            code: "bad_args",
            message: "destinationKey and bytes are required",
            details: nil
          )
        )
        return
      }
      DispatchQueue.global(qos: .utility).async {
        do {
          let path = try self.write(
            destinationKey: destinationKey,
            data: payload.data
          )
          DispatchQueue.main.async { result(path) }
        } catch {
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "icloud_write_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func write(destinationKey: String, data: Data) throws -> String {
    guard let container = ubiquityContainerURL() else {
      throw NSError(
        domain: "icloud",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "iCloud container is unavailable."]
      )
    }
    let documents = container.appendingPathComponent(
      "Documents",
      isDirectory: true
    )
    let destination = documents.appendingPathComponent(
      Self.sanitize(destinationKey)
    )
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let staging = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let incoming = destination.deletingLastPathComponent()
      .appendingPathComponent(".sonus-incoming-\(UUID().uuidString)")
    defer {
      try? fileManager.removeItem(at: staging)
      try? fileManager.removeItem(at: incoming)
    }
    try data.write(to: staging, options: .atomic)
    try fileManager.setUbiquitous(
      true,
      itemAt: staging,
      destinationURL: incoming
    )
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: incoming)
    } else {
      try fileManager.moveItem(at: incoming, to: destination)
    }
    return destination.path
  }

  private static func sanitize(_ key: String) -> String {
    let parts = key.split(separator: "/").map { component -> String in
      let scalars = component.unicodeScalars.filter { scalar in
        scalar != "\\" && !CharacterSet.controlCharacters.contains(scalar)
      }
      return String(String.UnicodeScalarView(scalars))
    }.filter { !$0.isEmpty && $0 != ".." }
    let joined = parts.joined(separator: "/")
    return joined.isEmpty ? "segment.m4a" : joined
  }
}
