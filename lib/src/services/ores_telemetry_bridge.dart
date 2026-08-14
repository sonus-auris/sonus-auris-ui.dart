import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:oresoftware_next_loggers/oresoftware_next_loggers.dart' as ores;
import 'package:uuid/uuid.dart';

import '../models/client_telemetry_event.dart';
import 'diagnostic_log.dart';

typedef OresTelemetrySink =
    FutureOr<void> Function(List<ClientTelemetryEvent> events);

/// Converts the app's diagnostics into the organization-wide
/// `next-loggers/v1` contract, emits an explicit OTEL log envelope, and hands
/// the same record to the authenticated Supabase outbox owned by the app.
///
/// This adapter never owns credentials and never opens its own socket. It is a
/// privacy boundary: user-authored audio/transcript/note fields are omitted and
/// auth material plus email addresses are redacted before either transport can
/// observe the record.
class OresTelemetryBridge {
  OresTelemetryBridge({
    required this.sessionId,
    required this.platform,
    required this.sendBatch,
    this.appVersion,
    int batchSize = 20,
    Duration flushInterval = const Duration(milliseconds: 250),
    String Function()? idFactory,
    DateTime Function()? clock,
  }) {
    _supabaseTransport = ores.SupabaseTransport(
      batchSize: batchSize,
      flushInterval: flushInterval,
      maxQueueSize: 100,
      sendBatch: _convertBatch,
    );
    _logger = ores.Logger(
      appName: 'sonus-auris-flutter',
      name: 'client',
      runtime: 'flutter',
      minimumLevel: ores.LogLevel.trace,
      console: false,
      fields: <String, Object?>{
        'platform': platform,
        'session_id': sessionId,
        if (appVersion != null && appVersion!.trim().isNotEmpty)
          'app_version': appVersion!.trim(),
      },
      idFactory: idFactory ?? _uuid.v4,
      clock: clock,
      transports: <ores.LogTransport>[
        ores.OpenTelemetryTransport(_captureOtelEnvelope),
        _supabaseTransport,
      ],
    );
  }

  static const Uuid _uuid = Uuid();

  final String sessionId;
  final String platform;
  final String? appVersion;
  final OresTelemetrySink sendBatch;
  final Map<String, Map<String, Object?>> _otelByRecordId = {};
  late final ores.SupabaseTransport _supabaseTransport;
  late final ores.Logger _logger;

  Future<void> record(DiagnosticEntry entry) async {
    final eventName = entry.event.trim().isEmpty
        ? 'diagnostic'
        : _sanitizeText(entry.event.trim(), 160);
    final traceId = _traceId(entry.details['traceId']?.toString());
    final spanId = _uuid.v4().replaceAll('-', '').substring(0, 16);
    final details = _sanitizeDetails(entry.details);
    final message = _sensitiveEvent(eventName)
        ? '[redacted user content]'
        : _sanitizeText(entry.message, 4000);
    final stack = entry.stack == null
        ? ''
        : _sanitizeText(entry.stack.toString(), 4000);
    final fields = <String, Object?>{
      'event': eventName,
      if (stack.isNotEmpty) 'diagnostic_stack': stack,
      ...details,
    };

    await ores.runWithLogContext(
      ores.LogContext(
        traceId: traceId,
        spanId: spanId,
        traceFlags: 1,
        tags: const <String>['sonus-auris', 'client'],
      ),
      () => _eventFor(entry.level, message).addFields(fields).send(),
    );
  }

  Future<void> flush() => _logger.flush();

  Future<void> close() => _logger.close();

  ores.LogEvent _eventFor(String level, String message) {
    switch (level.trim().toLowerCase()) {
      case 'trace':
        return _logger.trace(message);
      case 'debug':
        return _logger.debug(message);
      case 'warn':
      case 'warning':
        return _logger.warn(message);
      case 'error':
        return _logger.error(message);
      case 'fatal':
        return _logger.fatal(message);
      default:
        return _logger.info(message);
    }
  }

  void _captureOtelEnvelope(ores.JsonMap envelope) {
    final attributes = envelope['attributes'];
    if (attributes is! Map) {
      return;
    }
    final recordId = attributes['log.record.uid']?.toString() ?? '';
    if (recordId.isEmpty) {
      return;
    }
    if (_otelByRecordId.length >= 100) {
      _otelByRecordId.remove(_otelByRecordId.keys.first);
    }
    _otelByRecordId[recordId] = _sanitizeMap(envelope);
  }

  FutureOr<void> _convertBatch(List<ores.JsonMap> records) {
    final events = records.map(_convertRecord).toList(growable: false);
    return sendBatch(events);
  }

  ClientTelemetryEvent _convertRecord(ores.JsonMap record) {
    final fields = record['fields'] is Map
        ? _sanitizeMap((record['fields'] as Map).cast<Object?, Object?>())
        : <String, Object?>{};
    final recordId = record['id']?.toString() ?? _uuid.v4();
    final otel = _otelByRecordId.remove(recordId);
    final occurredAt = DateTime.tryParse(record['timestamp']?.toString() ?? '');
    final stack = fields.remove('diagnostic_stack')?.toString();
    final event = fields.remove('event')?.toString().trim() ?? '';
    final spanId = fields['otel.span_id']?.toString();

    return ClientTelemetryEvent(
      clientEventId: recordId,
      level: _normalizeLevel(record['level']?.toString()),
      event: event.isEmpty ? 'diagnostic' : event,
      message: _sanitizeText(record['message']?.toString() ?? '', 4000),
      occurredAtUtc: (occurredAt ?? DateTime.now()).toUtc(),
      stack: stack,
      platform: platform,
      appVersion: appVersion,
      sessionId: sessionId,
      source: 'ores-otel',
      transport: 'next-loggers+otel+supabase_rest_outbox+realtime_broadcast',
      traceId: record['traceId']?.toString(),
      spanId: spanId,
      details: <String, Object?>{
        'schema': record['schema']?.toString() ?? ores.schema,
        'runtime': record['runtime']?.toString() ?? 'flutter',
        'logger': record['name']?.toString() ?? 'client',
        'fields': fields,
        'otel_log_record': otel ?? const <String, Object?>{},
      },
    );
  }

  String _traceId(String? requested) {
    final value = (requested == null || requested.trim().isEmpty)
        ? sessionId
        : requested.trim();
    final compact = value.replaceAll('-', '').toLowerCase();
    if (RegExp(r'^[0-9a-f]{32}$').hasMatch(compact)) {
      return compact;
    }
    return sha256.convert(utf8.encode(value)).toString().substring(0, 32);
  }

  static String _normalizeLevel(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'trace':
        return 'trace';
      case 'debug':
        return 'debug';
      case 'warn':
      case 'warning':
        return 'warn';
      case 'error':
        return 'error';
      case 'fatal':
        return 'fatal';
      default:
        return 'info';
    }
  }

  static bool _sensitiveEvent(String event) {
    final lower = event.toLowerCase();
    return lower.contains('audio') ||
        lower.contains('transcript') ||
        lower.contains('speech') ||
        lower.contains('note') ||
        lower.contains('recording_content');
  }

  static Map<String, Object?> _sanitizeDetails(Map<dynamic, dynamic> source) {
    final clean = <String, Object?>{};
    for (final entry in source.entries.take(40)) {
      final key = entry.key.toString();
      final lower = key.toLowerCase();
      if (_sensitiveKey(lower)) {
        clean[key] =
            lower.contains('audio') ||
                lower.contains('transcript') ||
                lower.contains('speech') ||
                lower.contains('note') ||
                lower.contains('content')
            ? '[omitted]'
            : '[redacted]';
        continue;
      }
      clean[key] = _sanitizeValue(entry.value);
    }
    return clean;
  }

  static Map<String, Object?> _sanitizeMap(Map<dynamic, dynamic> source) =>
      _sanitizeDetails(source);

  static Object? _sanitizeValue(Object? value) {
    if (value == null || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) {
      return value.toUtc().toIso8601String();
    }
    if (value is Iterable) {
      return value.take(20).map(_sanitizeValue).toList(growable: false);
    }
    if (value is Map) {
      return _sanitizeMap(value);
    }
    return _sanitizeText(value.toString(), 1000);
  }

  static bool _sensitiveKey(String lower) =>
      lower.contains('token') ||
      lower.contains('secret') ||
      lower.contains('password') ||
      lower.contains('passphrase') ||
      lower.contains('authorization') ||
      lower.contains('credential') ||
      lower.contains('apikey') ||
      lower.contains('api_key') ||
      lower.contains('verifier') ||
      lower.contains('auth_code') ||
      lower.contains('authcode') ||
      lower.contains('jwt') ||
      lower.contains('otp') ||
      lower.contains('email') ||
      lower.contains('audio') ||
      lower.contains('transcript') ||
      lower.contains('speech') ||
      lower.contains('note') ||
      lower.contains('content');

  static String _sanitizeText(String value, int maxLength) {
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
          RegExp(r'eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*'),
          '[redacted-jwt]',
        )
        .replaceAllMapped(
          RegExp(
            r'''\b(access_token|refresh_token|id_token|provider_token|auth_code|code_verifier|apikey|api_key|token)=[^\s&"']+''',
            caseSensitive: false,
          ),
          (match) => '${match.group(1)}=[redacted]',
        )
        .replaceAll(
          RegExp(
            r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
            caseSensitive: false,
          ),
          '[redacted-email]',
        );
    if (clean.length > maxLength) {
      clean = '${clean.substring(0, maxLength)}…';
    }
    return clean;
  }
}
