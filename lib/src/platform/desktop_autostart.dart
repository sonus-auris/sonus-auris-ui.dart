// Registers the packaged desktop build as a login item (no-op on mobile).
import 'dart:io';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Registers the installed desktop app as a login item.
///
/// macOS release builds use `SMAppService.mainApp`, which launches the signed
/// Sonus Auris app bundle and preserves its bundle identity for TCC permission
/// prompts. Debug/profile runs never register themselves at login, preventing a
/// Terminal/debug executable from becoming the microphone permission owner.
class DesktopAutostart {
  static const _configuredKey = 'desktop.autostart.configured.v1';
  static const _macChannel = MethodChannel(
    'sonus_auris/desktop_autostart',
  );

  static bool get isSupported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static bool get canConfigure =>
      isSupported && (!Platform.isMacOS || kReleaseMode);

  /// Wires the cross-platform package on Windows/Linux. macOS uses the native
  /// ServiceManagement bridge, which needs no executable path.
  static void setup() {
    if (!(Platform.isWindows || Platform.isLinux)) return;
    launchAtStartup.setup(
      appName: 'Sonus Auris',
      appPath: Platform.resolvedExecutable,
    );
  }

  /// On the first packaged desktop launch, enable launch-at-login by default.
  /// A persisted marker means we never fight a user who later turns it off.
  static Future<void> enableByDefaultOnce() async {
    if (!canConfigure) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_configuredKey) ?? false) return;
      await _setEnabled(true);
      await prefs.setBool(_configuredKey, true);
    } catch (_) {
      // Login-item registration is best-effort; never block app startup.
    }
  }

  static Future<bool> isEnabled() async {
    if (!canConfigure) return false;
    try {
      if (Platform.isMacOS) {
        return await _macChannel.invokeMethod<bool>('isEnabled') ?? false;
      }
      return await launchAtStartup.isEnabled();
    } catch (_) {
      return false;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    if (!canConfigure) return;
    try {
      await _setEnabled(enabled);
    } catch (_) {
      // Best-effort; the UI re-reads the actual platform state.
    }
  }

  static Future<void> _setEnabled(bool enabled) async {
    if (Platform.isMacOS) {
      await _macChannel.invokeMethod<void>(
        'setEnabled',
        <String, Object>{'enabled': enabled},
      );
      return;
    }
    if (enabled) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
  }
}
