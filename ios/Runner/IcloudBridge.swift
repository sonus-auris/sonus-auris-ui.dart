import Flutter
import Foundation

/// Native side of the `audio_dashcam/icloud` MethodChannel. Writes segments the
/// backend cannot push (Apple has no server-side iCloud write API) into the
/// app's iCloud Drive container so they back up to the user's iCloud.
///
/// Requires the iCloud Documents capability + an `iCloud.<bundle-id>` container
/// on the Runner target (see ios/ICLOUD_SETUP.md). Without it, `isAvailable`
/// returns false and the Dart layer simply skips iCloud mirroring.
final class IcloudBridge {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "audio_dashcam/icloud",
      binaryMessenger: messenger
    )
    let instance = IcloudBridge()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private let fileManager = FileManager.default

  private func ubiquityContainerURL() -> URL? {
    // nil identifier resolves the app's default iCloud container.
    return fileManager.url(forUbiquityContainerIdentifier: nil)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      let signedIn = fileManager.ubiquityIdentityToken != nil
      result(signedIn && ubiquityContainerURL() != nil)

    case "importSegment":
      guard
        let args = call.arguments as? [String: Any],
        let destinationKey = args["destinationKey"] as? String,
        let payload = args["bytes"] as? FlutterStandardTypedData
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
      // Disk + iCloud I/O off the platform thread.
      DispatchQueue.global(qos: .utility).async {
        do {
          let path = try self.writeToICloud(
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

  private func writeToICloud(destinationKey: String, data: Data) throws -> String {
    guard let container = ubiquityContainerURL() else {
      throw NSError(
        domain: "icloud",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "iCloud container is unavailable."]
      )
    }
    // Documents/ is user-visible in the Files / iCloud Drive app.
    let documents = container.appendingPathComponent("Documents", isDirectory: true)
    let relative = IcloudBridge.sanitize(destinationKey)
    let destination = documents.appendingPathComponent(relative)
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    // Stage locally, then hand the file to iCloud (Apple's recommended pattern).
    let staging = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let incoming = destination.deletingLastPathComponent()
      .appendingPathComponent(".sonus-incoming-\(UUID().uuidString)")
    defer {
      try? fileManager.removeItem(at: staging)
      try? fileManager.removeItem(at: incoming)
    }
    try data.write(to: staging, options: .atomic)
    try fileManager.setUbiquitous(true, itemAt: staging, destinationURL: incoming)
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: incoming)
    } else {
      try fileManager.moveItem(at: incoming, to: destination)
    }
    return destination.path
  }

  /// Maps a backend destination key to a safe relative path (no traversal,
  /// no backslashes / control characters).
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
