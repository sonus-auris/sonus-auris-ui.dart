// Registers the desktop build as a login item so it starts at login (no-op on mobile).
import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Registers the desktop build as a login item so it starts at login (the
/// desktop sibling of the mobile "always-on" boot-start). No-op on mobile.
///
/// On first run it opts in by default; a persisted marker means we never fight a
/// user who later turns it off. Every call is best-effort and fails soft.
class DesktopAutostart {
  static const _configuredKey = 'desktop.autostart.configured.v1';

  static bool get isSupported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Wires the package to this executable. Call once before enable/disable.
  static void setup() {
    if (!isSupported) return;
    launchAtStartup.setup(
      appName: 'Sonus Auris',
      appPath: Platform.resolvedExecutable,
    );
  }

  /// On the first desktop launch, enable launch-at-login by default. Honors the
  /// user's later choice on subsequent runs.
  static Future<void> enableByDefaultOnce() async {
    if (!isSupported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_configuredKey) ?? false) {
        return;
      }
      await launchAtStartup.enable();
      await prefs.setBool(_configuredKey, true);
    } catch (_) {
      // Login-item registration is best-effort; never block app startup.
    }
  }

  static Future<bool> isEnabled() async {
    if (!isSupported) return false;
    try {
      return await launchAtStartup.isEnabled();
    } catch (_) {
      return false;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    if (!isSupported) return;
    try {
      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } catch (_) {
      // best-effort
    }
  }
}
