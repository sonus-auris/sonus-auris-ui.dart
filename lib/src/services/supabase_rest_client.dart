// Thin PostgREST client that writes user rows into Supabase using only the signed-in user's token (RLS-scoped).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/acoustic_detection.dart';
import '../models/app_config.dart';
import '../models/client_telemetry_event.dart';
import '../models/cloud_secrets.dart';
import '../models/consent.dart';
import 'supabase_key_policy.dart';

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
  static const String clientTelemetryTable = 'client_telemetry';

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
    // Sleep-cycle rows carry enriched sensor/context fields and only leave the
    // device with their own explicit consent — fail closed and keep them local
    // otherwise. Filtered here so every caller inherits the gate.
    final uploadable = config.sleepCloudSyncConsent
        ? detections
        : detections.where((d) => !_isSleepCycleKind(d.kind)).toList();
    if (uploadable.isEmpty) {
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
    final rows = uploadable
        .map((d) => d.toSupabaseRow(config.deviceId))
        .toList();
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

  /// Inserts sanitized client-side logs/errors for observability. Telemetry is
  /// append-only and RLS-scoped to the signed-in user; callers should treat
  /// failures as non-fatal.
  Future<String?> insertTelemetry({
    required AppConfig config,
    required CloudSecrets secrets,
    required List<ClientTelemetryEvent> events,
  }) async {
    if (events.isEmpty) {
      return null;
    }
    if (!canInsert(config, secrets)) {
      return 'Supabase URL, anon key, and a signed-in session are required.';
    }
    final Uri uri;
    try {
      uri = _restUri(config, clientTelemetryTable);
    } on FormatException catch (error) {
      return error.message;
    }
    final rows = events
        .map(
          (event) =>
              _sanitizeTelemetryRow(event.toSupabaseRow(config.deviceId)),
        )
        .toList();
    try {
      final response = await _httpClient
          .post(uri, headers: _headers(config, secrets), body: jsonEncode(rows))
          .timeout(requestTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return null;
      }
      return 'Supabase telemetry insert failed (${response.statusCode}): '
          '${_shortBody(response.body)}';
    } catch (error) {
      return 'Supabase telemetry insert error: $error';
    }
  }

  void close() {
    _httpClient.close();
  }

  static bool _isSleepCycleKind(AcousticDetectionKind kind) {
    return kind == AcousticDetectionKind.sleepCycle ||
        kind == AcousticDetectionKind.sleepCycleAlarm;
  }

  Uri _restUri(AppConfig config, String table) {
    requireSafeSupabaseClientKey(config.supabaseAnonKey);
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
    return base
        .replace(pathSegments: [...baseSegments, 'rest', 'v1', table])
        .removeFragment();
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

  Map<String, Object?> _sanitizeTelemetryRow(Map<String, Object?> row) {
    return row.map((key, value) {
      if (key == 'message' || key == 'stack') {
        return MapEntry(key, _redactAndTruncate(value?.toString() ?? '', 4000));
      }
      if (key == 'details' && value is Map) {
        return MapEntry(key, _sanitizeTelemetryDetails(value));
      }
      return MapEntry(key, value);
    });
  }

  Map<String, Object?> _sanitizeTelemetryDetails(
    Map<dynamic, dynamic> details,
  ) {
    final clean = <String, Object?>{};
    for (final entry in details.entries.take(40)) {
      final key = entry.key.toString();
      if (_looksSecretKey(key)) {
        clean[key] = '[redacted]';
        continue;
      }
      clean[key] = _sanitizeTelemetryValue(entry.value);
    }
    return clean;
  }

  Object? _sanitizeTelemetryValue(Object? value) {
    if (value == null || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) {
      return value.toUtc().toIso8601String();
    }
    if (value is Iterable) {
      return value.take(20).map(_sanitizeTelemetryValue).toList();
    }
    if (value is Map) {
      return _sanitizeTelemetryDetails(value);
    }
    return _redactAndTruncate(value.toString(), 1000);
  }

  bool _looksSecretKey(String key) {
    final lower = key.toLowerCase();
    return lower.contains('token') ||
        lower.contains('secret') ||
        lower.contains('password') ||
        lower.contains('authorization') ||
        lower.contains('apikey') ||
        lower.contains('api_key');
  }

  String _redactAndTruncate(String value, int maxLength) {
    var clean = value
        .replaceAll(
          RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
          'Bearer [redacted]',
        )
        .replaceAll(
          RegExp(r'sb_(?:secret|service_role)_[A-Za-z0-9._~-]+'),
          'sb_[redacted]',
        )
        .replaceAll(
          RegExp(r'postgresql://[^\s]+', caseSensitive: false),
          'postgresql://[redacted]',
        );
    if (clean.length > maxLength) {
      clean = '${clean.substring(0, maxLength)}…';
    }
    return clean;
  }
}
