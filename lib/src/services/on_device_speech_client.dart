// Dart side of the on-device (offline) speech-recognition bridge, keeping transcription inside the local plaintext window.
import 'dart:io';

import 'package:flutter/services.dart';

/// Dart side of the **on-device** speech-recognition bridge.
///
/// Because audio is encrypted before it leaves the phone, transcription has to
/// happen here, inside the local plaintext window — the cloud only ever holds
/// ciphertext it can't read. This bridge runs the platform's *offline*
/// recognizer and never sends audio anywhere:
///
///   * iOS — `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`
///     (falls back to unavailable rather than going to Apple's servers).
///   * Android — `SpeechRecognizer` with an on-device recognition model.
///
/// The native side is expected to register a `audio_dashcam/stt` method channel
/// exposing:
///   * `isAvailable` → bool — an on-device model is installed & usable.
///   * `transcribe` { pcm: Uint8List, sampleRate: int, channels: int }
///       → { text: String } | null
///
/// All methods fail soft (return null/false) so a missing model or platform
/// error never breaks capture or analysis.
class OnDeviceSpeechClient {
  OnDeviceSpeechClient({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('audio_dashcam/stt');

  final MethodChannel _channel;

  /// Whether on-device speech recognition is plausibly supported on this OS.
  /// The authoritative check is [isAvailable], which asks the native model.
  bool get isSupported => Platform.isIOS || Platform.isAndroid;

  /// Asks the native layer whether an on-device recognition model is installed
  /// and ready. Returns false on any error or unsupported platform.
  Future<bool> isAvailable() async {
    if (!isSupported) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Transcribes a short clip of interleaved PCM16 entirely on-device. Returns
  /// the transcript, or null when unsupported, unavailable, or nothing was
  /// recognised. Audio never leaves the device.
  Future<String?> transcribe({
    required Uint8List pcm16,
    required int sampleRate,
    required int channels,
  }) async {
    if (!isSupported || pcm16.isEmpty) {
      return null;
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'transcribe',
        {
          'pcm': pcm16,
          'sampleRate': sampleRate,
          'channels': channels,
        },
      );
      final text = (result?['text'] as String?)?.trim();
      return (text == null || text.isEmpty) ? null : text;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // Native side not wired yet (e.g. older build); fail soft.
      return null;
    }
  }
}
