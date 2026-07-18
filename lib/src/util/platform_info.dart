// Platform identity WITHOUT dart:io, so every call site is web-safe.
import 'package:flutter/foundation.dart';

/// Wire value for the `devices.platform` column (one of
/// `devicesPlatformValues` in the interfaces package). `kIsWeb` wins over
/// [defaultTargetPlatform] so mobile web correctly reports `web`.
String platformWire() {
  if (kIsWeb) {
    return 'web';
  }
  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.linux:
      return 'linux';
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.fuchsia:
      // Not in the schema's enum; closest desktop-ish bucket.
      return 'linux';
  }
}

/// Human label for a `devices.platform` wire value.
String platformLabel(String wire) {
  switch (wire) {
    case 'macos':
      return 'macOS';
    case 'windows':
      return 'Windows';
    case 'linux':
      return 'Linux';
    case 'android':
      return 'Android';
    case 'ios':
      return 'iOS';
    case 'web':
      return 'Web';
    default:
      return wire;
  }
}

/// Default display name for this console install's own device row.
String defaultConsoleName() {
  return kIsWeb ? 'Web console' : 'Console on ${platformLabel(platformWire())}';
}

/// True when running as a NATIVE iOS/Android binary — i.e. a build that would
/// ship through the App Store / Play Store. Mobile *web* (Safari/Chrome on a
/// phone) is not a store binary: `kIsWeb` is true there. Used to hide the
/// Stripe billing path, which store policies forbid inside native apps.
bool get isNativeMobileStoreBinary =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);
