import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/acoustic_detection.dart';
import '../models/app_config.dart';
import '../models/cloud_secrets.dart';
import '../models/consent.dart';

/// Thin PostgREST client for writing user data into Supabase. Only the signed-in
/// user's access token is used (never a service key), so row-level-security
/// `auth.uid()` policies scope every insert to that user.
class SupabaseRestClient {
  SupabaseRestClient({
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration requestTimeout;

  static const String acousticEventsTable = 'acoustic_events';

  /// Whether an insert can even be attempted with the current config/secrets.
  bool canInsert(AppConfig config, CloudSecrets secrets) {
    return config.supabaseUrl.trim().isNotEmpty &&
        config.supabaseAnonKey.trim().isNotEmpty &&
        secrets.hasSupabaseToken;
  }

  /// Batch-inserts acoustic detections. Returns an error string on failure, or
  /// null on success (including when there is nothing to insert).
  Future<String?> insertDetections({
    required AppConfig config,
    required CloudSecrets secrets,
    required List<AcousticDetection> detections,
  }) async {
    if (detections.isEmpty) {
      return null;
    }
    if (!canInsert(config, secrets)) {
      return 'Supabase URL, anon key, and a signed-in session are required.';
    }
    final Uri uri;
    try {
      uri = _restUri(config, acousticEventsTable);
    } on FormatException catch (error) {
      return error.message;
    }
    final rows =
        detections.map((d) => d.toSupabaseRow(config.deviceId)).toList();
    try {
      final response = await _httpClient
          .post(uri, headers: _headers(config, secrets), body: jsonEncode(rows))
          .timeout(requestTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return null;
      }
      return 'Supabase insert failed (${response.statusCode}): '
          '${_shortBody(response.body)}';
    } catch (error) {
      return 'Supabase insert error: $error';
    }
  }

  void close() {
    _httpClient.close();
  }

  Uri _restUri(AppConfig config, String table) {
    final base = Uri.parse(config.supabaseUrl.trim());
    if (base.host.trim().isEmpty) {
      throw const FormatException('Supabase URL must include a host.');
    }
    if (base.scheme != 'https' &&
        base.host != 'localhost' &&
        base.host != '127.0.0.1') {
      throw const FormatException(
        'Supabase URL must use HTTPS except localhost development.',
      );
    }
    final baseSegments = base.pathSegments.where((p) => p.isNotEmpty);
    return base.replace(
      pathSegments: [...baseSegments, 'rest', 'v1', table],
    ).removeFragment();
  }

  Map<String, String> _headers(AppConfig config, CloudSecrets secrets) {
    return {
      'apikey': config.supabaseAnonKey.trim(),
      'authorization': 'Bearer ${secrets.supabaseAccessToken.trim()}',
      'content-type': 'application/json',
      // Don't echo inserted rows back; we only need the write to succeed.
      'prefer': 'return=minimal',
    };
  }

  String _shortBody(String body) {
    final trimmed = body.trim();
    return trimmed.length > 200 ? trimmed.substring(0, 200) : trimmed;
  }
}
