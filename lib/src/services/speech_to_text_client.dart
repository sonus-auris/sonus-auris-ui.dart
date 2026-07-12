// Cloud speech-to-text client used to scan transcripts for magic-phrase keywords.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/app_config.dart';
import '../models/cloud_secrets.dart';

/// Result of a keyword scan over a transcript.
class KeywordMatch {
  const KeywordMatch({required this.keyword, required this.transcript});

  final String keyword;
  final String transcript;
}

/// Opt-in cloud speech-to-text. POSTs a short WAV clip to a user-configured
/// endpoint and scans the returned transcript for keywords. Audio leaves the
/// device only when [AppConfig.sttEnabled] is set and an endpoint is configured.
class SpeechToTextClient {
  SpeechToTextClient({
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration requestTimeout;

  bool canTranscribe(AppConfig config) =>
      config.sttEnabled && config.sttEndpoint.trim().isNotEmpty;

  /// Sends [pcm16] (mono/stereo little-endian PCM16 at [sampleRate]) wrapped as
  /// a WAV to the configured endpoint and returns the transcript, or null on
  /// failure.
  Future<String?> transcribe({
    required AppConfig config,
    required CloudSecrets secrets,
    required Uint8List pcm16,
    required int sampleRate,
    required int channels,
  }) async {
    if (!canTranscribe(config) || pcm16.isEmpty) {
      return null;
    }
    final Uri uri;
    try {
      uri = _endpointUri(config);
    } on FormatException {
      return null;
    }
    final wav = wavBytesFromPcm16(pcm16, sampleRate, channels);
    final headers = <String, String>{'content-type': 'audio/wav'};
    if (secrets.hasSttApiKey) {
      headers['authorization'] = 'Bearer ${secrets.sttApiKey.trim()}';
    }
    try {
      final response = await _httpClient
          .post(uri, headers: headers, body: wav)
          .timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      return _extractTranscript(response.body);
    } catch (_) {
      return null;
    }
  }

  /// First keyword (from [config.keywords]) that appears in the transcript, or
  /// null. Case-insensitive, whole-word-ish (substring after lowercasing).
  KeywordMatch? matchKeyword(AppConfig config, String transcript) {
    final lower = transcript.toLowerCase();
    for (final keyword in config.keywords) {
      final needle = keyword.trim().toLowerCase();
      if (needle.isNotEmpty && lower.contains(needle)) {
        return KeywordMatch(keyword: keyword.trim(), transcript: transcript);
      }
    }
    return null;
  }

  void close() {
    _httpClient.close();
  }

  Uri _endpointUri(AppConfig config) {
    final uri = Uri.parse(config.sttEndpoint.trim());
    if (uri.host.trim().isEmpty) {
      throw const FormatException('STT endpoint must include a host.');
    }
    if (uri.scheme != 'https' &&
        uri.host != 'localhost' &&
        uri.host != '127.0.0.1') {
      throw const FormatException(
        'STT endpoint must use HTTPS except localhost development.',
      );
    }
    return uri;
  }

  /// Pulls a transcript out of common STT JSON shapes; falls back to plain text.
  String? _extractTranscript(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        for (final key in const ['text', 'transcript']) {
          final value = decoded[key];
          if (value is String && value.trim().isNotEmpty) {
            return value.trim();
          }
        }
        // Google-style: results[].alternatives[].transcript
        final results = decoded['results'];
        if (results is List && results.isNotEmpty) {
          final parts = <String>[];
          for (final r in results) {
            final alts = (r as Map)['alternatives'];
            if (alts is List && alts.isNotEmpty) {
              final t = (alts.first as Map)['transcript'];
              if (t is String) {
                parts.add(t);
              }
            }
          }
          if (parts.isNotEmpty) {
            return parts.join(' ').trim();
          }
        }
      }
    } catch (_) {
      // Not JSON — treat as plain text.
    }
    final trimmed = body.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Wraps raw interleaved PCM16 in a 44-byte canonical WAV header.
Uint8List wavBytesFromPcm16(Uint8List pcm, int sampleRate, int channels) {
  final ch = channels < 1 ? 1 : channels;
  final byteRate = sampleRate * ch * 2;
  final blockAlign = ch * 2;
  final dataSize = pcm.length;
  final out = Uint8List(44 + dataSize);
  final data = ByteData.sublistView(out);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + dataSize, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, ch, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, byteRate, Endian.little);
  data.setUint16(32, blockAlign, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, dataSize, Endian.little);
  out.setRange(44, 44 + dataSize, pcm);
  return out;
}
