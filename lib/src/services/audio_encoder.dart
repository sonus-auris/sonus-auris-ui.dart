// Dart side of the native on-device audio-compression bridge (WAV -> AAC/M4A) used before publishing a Day of My Life.
import 'package:flutter/services.dart';

/// Compressed audio plus the metadata an upload needs.
class EncodedAudio {
  const EncodedAudio({
    required this.bytes,
    required this.contentType,
    required this.fileExtension,
  });

  final Uint8List bytes;
  final String contentType;
  final String fileExtension;
}

/// Dart side of the on-device audio-compression bridge. A 24-hour WAV is
/// gigabytes; before it can become a "Day of My Life" track it has to be
/// compressed to AAC/M4A on-device — no audio leaves the phone to do this.
///
/// Native contract (`audio_dashcam/encoder` method channel):
///   * iOS — `AVAudioConverter` / `AVAssetWriter` → AAC in an .m4a container.
///   * Android — `MediaCodec` AAC encoder + `MediaMuxer` → .m4a.
///   * `encodeAac` { wav: Uint8List, bitRate: int } → { bytes: Uint8List } | null
///
/// Fails soft: if the native encoder is missing or errors, [encodeToAac]
/// returns null and the caller falls back to uploading the raw WAV.
class AudioEncoder {
  AudioEncoder({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('audio_dashcam/encoder');

  final MethodChannel _channel;

  /// Encodes interleaved PCM16 WAV [wavBytes] to AAC/M4A at [bitRate] bps.
  /// Returns null when unavailable so callers can fall back to WAV.
  Future<EncodedAudio?> encodeToAac({
    required Uint8List wavBytes,
    int bitRate = 96000,
  }) async {
    if (wavBytes.isEmpty) {
      return null;
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'encodeAac',
        {'wav': wavBytes, 'bitRate': bitRate},
      );
      final bytes = result?['bytes'];
      if (bytes is! Uint8List || bytes.isEmpty) {
        return null;
      }
      return EncodedAudio(
        bytes: bytes,
        contentType: 'audio/mp4',
        fileExtension: 'm4a',
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
