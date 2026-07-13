// Dart side of the iOS-only ShazamKit song-identification bridge.
import 'dart:io';

import 'package:flutter/services.dart';

/// A song identified by ShazamKit.
class ShazamMatch {
  const ShazamMatch({required this.title, required this.artist});

  final String title;
  final String artist;

  Map<String, Object?> toDetails() => {'title': title, 'artist': artist};
}

/// Dart side of the ShazamKit bridge. Song identification is **iOS only** — on
/// every other platform [identify] returns null and no audio leaves the device.
/// Apple's ShazamKit runs the match against its catalog; only a derived audio
/// signature is sent, and only when the user has enabled Shazam.
class ShazamClient {
  ShazamClient({
    MethodChannel? channel,
    this.timeout = const Duration(seconds: 12),
  }) : _channel = channel ?? const MethodChannel('audio_dashcam/shazam');

  final MethodChannel _channel;

  /// Upper bound on a match attempt. ShazamKit normally answers in 1–3 s; the
  /// timeout guards against a native callback that never fires so a match can
  /// never stall detection handling.
  final Duration timeout;

  /// Whether song identification is available on this platform.
  bool get isSupported => Platform.isIOS;

  /// Identifies a song from a short clip of interleaved PCM16. Returns null when
  /// unsupported, on error, or when nothing matched.
  Future<ShazamMatch?> identify({
    required Uint8List pcm16,
    required int sampleRate,
    required int channels,
  }) async {
    if (!isSupported || pcm16.isEmpty) {
      return null;
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('match', {
        'pcm': pcm16,
        'sampleRate': sampleRate,
        'channels': channels,
      }).timeout(timeout, onTimeout: () => null);
      if (result == null) {
        return null;
      }
      final title = (result['title'] as String?)?.trim() ?? '';
      final artist = (result['artist'] as String?)?.trim() ?? '';
      if (title.isEmpty && artist.isEmpty) {
        return null;
      }
      return ShazamMatch(title: title, artist: artist);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // Native side not wired (e.g. older build); fail soft.
      return null;
    }
  }
}
