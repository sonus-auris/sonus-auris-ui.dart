// Form-factor / device-role enums and static platform helpers shared across mobile and desktop.
import 'package:flutter/foundation.dart';

/// Form factor this build is running on. Drives *presentation* only — the
/// `AppController` and all services are shared across mobile and desktop.
enum FormFactor { mobile, desktop }

/// The role a build plays in the multi-device account. Drives *logic*
/// differences explicitly, so the shared codebase never has to guess:
///
///   * [recorder] — phones and the Flutter desktop build: captures **this**
///     device's audio and shows only this device's data.
///   * [masterViewer] — browses/decrypts **all** devices' audio (the purpose-
///     built Rust `desktop.app.rs` owns this role today; a Flutter build could
///     opt into it later behind the account private key).
enum DeviceRole { recorder, masterViewer }

/// Static platform/form-factor helpers. Kept tiny and dependency-free so it can
/// be imported anywhere (UI or logic) without pulling in `dart:io`.
class Platforms {
  const Platforms._();

  static bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  static FormFactor get formFactor =>
      isDesktop ? FormFactor.desktop : FormFactor.mobile;

  /// On desktop the Flutter build is "the recorder, on a bigger screen": the
  /// same single-device logic as mobile, never the master viewer.
  static DeviceRole get role => DeviceRole.recorder;

  /// Comfortable max content width on desktop so the mobile layout reads as a
  /// centered desktop panel rather than a stretched phone.
  static const double desktopContentMaxWidth = 760;
}
