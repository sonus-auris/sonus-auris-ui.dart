// Thin PostgREST client that writes user rows into Supabase using only the signed-in user's token (RLS-scoped).
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

  /// Onboarding consent records.
  ///
  /// Expected Supabase schema (RLS scopes every row to the authed user):
  /// ```sql
  /// create table public.user_consents (
  ///   id           uuid primary key default gen_random_uuid(),
  ///   user_id      uuid not null default auth.uid() references auth.users(id),
  ///   device_id    text not null,
  ///   consent_version text not null,
  ///   platform     text,
  ///   granted      jsonb not null,
  ///   accepted_at  timestamptz not null,
  ///   created_at   timestamptz not null default now()
  /// );
  /// alter table public.user_consents enable row level security;
  /// create policy "own consents" on public.user_consents
  ///   for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
  /// ```
  static const String userConsentsTable = 'user_consents';

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

  /// Inserts the onboarding [record] for the signed-in user. Returns an error
  /// string on failure, or null on success.
  Future<String?> insertConsent({
    required AppConfig config,
    required CloudSecrets secrets,
    required ConsentRecord record,
  }) async {
    if (!canInsert(config, secrets)) {
      return 'Supabase URL, anon key, and a signed-in session are required.';
    }
    final Uri uri;
    try {
      uri = _restUri(config, userConsentsTable);
    } on FormatException catch (error) {
      return error.message;
    }
    try {
      final response = await _httpClient
          .post(
            uri,
            headers: _headers(config, secrets),
            body: jsonEncode([record.toSupabaseRow(config.deviceId)]),
          )
          .timeout(requestTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return null;
      }
      return 'Supabase consent insert failed (${response.statusCode}): '
          '${_shortBody(response.body)}';
    } catch (error) {
      return 'Supabase consent insert error: $error';
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
