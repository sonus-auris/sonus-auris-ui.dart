// Free-disk-space lookup behind the audio_dashcam/device_storage MethodChannel.
import 'dart:io';

import 'package:flutter/services.dart';

/// Reports the free bytes available to the app on the volume holding [path].
///
/// Backed by StatFs on Android and FileManager/volumeAvailableCapacity on iOS.
/// Returns null wherever the platform channel is unavailable (desktop builds,
/// tests) so callers treat free space as unknown and skip space-based pruning
/// rather than guessing.
class DeviceStorageInfo {
  DeviceStorageInfo({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('audio_dashcam/device_storage');

  final MethodChannel _channel;

  Future<int?> freeBytes(String path) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return null;
    }
    try {
      final value = await _channel.invokeMethod<Object?>('freeBytes', {
        'path': path,
      });
      if (value is int && value >= 0) {
        return value;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
