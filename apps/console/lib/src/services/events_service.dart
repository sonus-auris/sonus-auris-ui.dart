// Reads acoustic detection events for the account (RLS-scoped to the owner).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart'
    as interfaces;

import '../config/console_config.dart';
import 'key_policy.dart';

typedef EventsResult = ({List<interfaces.AcousticEvent> events, String? error});

class EventsService {
  EventsService({
    required this.config,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _http = httpClient ?? http.Client();

  final ConsoleConfig config;
  final http.Client _http;
  final Duration requestTimeout;

  /// Most recent detections, newest first. Optionally filtered to one device.
  Future<EventsResult> list(
    String accessToken, {
    int limit = 100,
    String? deviceId,
  }) async {
    final Uri uri;
    try {
      uri = _restUri().replace(
        queryParameters: {
          'select': '*',
          'order': 'started_at.desc',
          'limit': '$limit',
          if ((deviceId ?? '').trim().isNotEmpty) 'device_id': 'eq.$deviceId',
        },
      );
    } on FormatException catch (e) {
      return (events: const <interfaces.AcousticEvent>[], error: e.message);
    }
    try {
      final response = await _http
          .get(uri, headers: _headers(accessToken))
          .timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          events: const <interfaces.AcousticEvent>[],
          error: 'Events read failed (${response.statusCode}).',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        return (
          events: const <interfaces.AcousticEvent>[],
          error: 'Events read returned an invalid response.',
        );
      }
      final events = <interfaces.AcousticEvent>[];
      for (final row in decoded) {
        if (row is Map) {
          try {
            events.add(
              interfaces.AcousticEvent.fromJson(row.cast<String, Object?>()),
            );
          } catch (_) {
            // skip malformed
          }
        }
      }
      return (events: events, error: null);
    } catch (e) {
      return (
        events: const <interfaces.AcousticEvent>[],
        error: 'Events read error: $e',
      );
    }
  }

  Uri _restUri() {
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
    return base.replace(
      pathSegments: [
        ...baseSegments,
        'rest',
        'v1',
        interfaces.acousticEventsTable,
      ],
    );
  }

  Map<String, String> _headers(String accessToken) {
    return {
      'apikey': config.supabaseAnonKey.trim(),
      'authorization': 'Bearer ${accessToken.trim()}',
      'accept': 'application/json',
    };
  }

  void close() {
    _http.close();
  }
}
