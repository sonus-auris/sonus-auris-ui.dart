import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Web-safe platform probes.
///
/// `dart:io` compiles to a web stub, but reading any [Platform] property there
/// throws at runtime. Keeping every probe behind [kIsWeb] lets the primary app
/// boot in Flutter web while preserving native behavior on phones and desktop.
abstract final class RuntimePlatform {
  static bool get isWeb => kIsWeb;
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;
  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isMacOS => !kIsWeb && Platform.isMacOS;
  static bool get isWindows => !kIsWeb && Platform.isWindows;
  static bool get isLinux => !kIsWeb && Platform.isLinux;

  static String get operatingSystem =>
      kIsWeb ? 'web' : Platform.operatingSystem;

  static String get resolvedExecutable =>
      kIsWeb ? '' : Platform.resolvedExecutable;
}
