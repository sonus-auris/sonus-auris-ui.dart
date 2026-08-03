// Registers the packaged desktop build as a login item (no-op on mobile).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Compile-time safety boundary for packaged runtime probes.
///
/// The device-lab app is launched with an isolated bundle identifier and this
/// flag set. It must never inspect, migrate, disable, or register the operator's
/// real Sonus Auris login item while testing launch/Quit behavior.
const bool kSonusDeviceLabNoSideEffects = bool.fromEnvironment(
  'SONUS_DEVICE_LAB_NO_SIDE_EFFECTS',
  defaultValue: false,
);

/// Registers the installed desktop app as a login item.
///
/// macOS release builds use `SMAppService.mainApp`, which launches the signed
/// Sonus Auris app bundle and preserves its bundle identity for TCC permission
/// prompts. Debug/profile runs never register themselves at login, preventing a
/// Terminal/debug executable from becoming the microphone permission owner.
class DesktopAutostart {
  static const _configuredKey = 'desktop.autostart.configured.v1';
  static const _macMigrationKey =
      'desktop.autostart.macos.smappservice.migrated.v1';
  static const _macLegacyEnabledKey =
      'desktop.autostart.macos.legacy-enabled.v1';
  static const _macChannel = MethodChannel(
    'sonus_auris/desktop_autostart',
  );

  static Future<void>? _macMigration;

  static bool get isSupported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static bool get canConfigure =>
      !kSonusDeviceLabNoSideEffects &&
      isSupported &&
      (!Platform.isMacOS || kReleaseMode);

  /// Wires the legacy cross-platform package on every desktop platform. On
  /// macOS it is used only to detect and remove an older LaunchAgent that may
  /// point at Terminal/a debug executable; packaged startup is owned by the
  /// native `SMAppService.mainApp` bridge.
  static void setup() {
    if (!isSupported || kSonusDeviceLabNoSideEffects) return;
    launchAtStartup.setup(
      appName: 'Sonus Auris',
      appPath: Platform.resolvedExecutable,
    );
    if (Platform.isMacOS) {
      _macMigration ??= _migrateLegacyMacRegistration();
      unawaited(_macMigration);
    }
  }

  /// On the first packaged desktop launch, enable launch-at-login by default.
  /// A persisted marker means we never fight a user who later turns it off.
  static Future<void> enableByDefaultOnce() async {
    if (!canConfigure) return;
    try {
      await _awaitMacMigration();
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
      await _awaitMacMigration();
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
      await _awaitMacMigration();
      await _setEnabled(enabled);
    } catch (_) {
      // Best-effort; the UI re-reads the actual platform state.
    }
  }

  static Future<void> _awaitMacMigration() async {
    if (kSonusDeviceLabNoSideEffects || !Platform.isMacOS) return;
    _macMigration ??= _migrateLegacyMacRegistration();
    await _macMigration;
  }

  /// Preserves the user's legacy enabled/disabled choice while moving startup
  /// from launch_at_startup's LaunchAgent to the signed Sonus Auris app bundle.
  ///
  /// A debug run may perform the cleanup first. In that case it records that the
  /// legacy item was enabled, and the next packaged release completes the native
  /// registration instead of allowing Terminal to remain the permission owner.
  static Future<void> _migrateLegacyMacRegistration() async {
    if (kSonusDeviceLabNoSideEffects) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_macMigrationKey) ?? false) return;

    var legacyWasEnabled = prefs.getBool(_macLegacyEnabledKey) ?? false;
    try {
      legacyWasEnabled =
          legacyWasEnabled || await launchAtStartup.isEnabled();
    } catch (_) {
      // Continue with any state captured by an earlier debug launch.
    }

    try {
      await launchAtStartup.disable();
    } catch (_) {
      // Best-effort. Do not mark migration complete if release registration is
      // still required and cannot be verified below.
    }

    if (legacyWasEnabled) {
      await prefs.setBool(_macLegacyEnabledKey, true);
    }
    if (!kReleaseMode) return;

    if (legacyWasEnabled) {
      await _macChannel.invokeMethod<void>(
        'setEnabled',
        const <String, Object>{'enabled': true},
      );
    }
    await prefs.remove(_macLegacyEnabledKey);
    await prefs.setBool(_macMigrationKey, true);
  }

  static Future<void> _setEnabled(bool enabled) async {
    if (kSonusDeviceLabNoSideEffects) return;
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
