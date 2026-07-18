import 'package:uuid/uuid.dart';

/// A sanitized client observability event. [clientEventId] is generated on the
/// device so a timed-out REST insert can be retried without duplicating rows.
class ClientTelemetryEvent {
  ClientTelemetryEvent({
    required this.level,
    required this.event,
    required this.message,
    required this.occurredAtUtc,
    String? clientEventId,
    this.stack,
    this.platform,
    this.appVersion,
    this.sessionId,
    this.source = 'flutter',
    this.transport = 'rest_outbox',
    this.traceId,
    this.spanId,
    this.parentSpanId,
    this.details = const {},
  }) : clientEventId = _normalizeId(clientEventId);

  static final Uuid _uuid = Uuid();

  final String clientEventId;

  final String level;
  final String event;
  final String message;
  final DateTime occurredAtUtc;
  final String? stack;
  final String? platform;
  final String? appVersion;
  final String? sessionId;
  final String source;
  final String transport;
  final String? traceId;
  final String? spanId;
  final String? parentSpanId;
  final Map<String, Object?> details;

  Map<String, Object?> toSupabaseRow(String deviceId) => {
    'device_id': deviceId,
    'client_event_id': clientEventId,
    'level': level,
    'event': event,
    'message': message,
    'occurred_at': occurredAtUtc.toIso8601String(),
    if (stack != null && stack!.trim().isNotEmpty) 'stack': stack,
    if (platform != null && platform!.trim().isNotEmpty) 'platform': platform,
    if (appVersion != null && appVersion!.trim().isNotEmpty)
      'app_version': appVersion,
    if (sessionId != null && sessionId!.trim().isNotEmpty)
      'session_id': sessionId,
    if (source.trim().isNotEmpty) 'source': source,
    if (transport.trim().isNotEmpty) 'transport': transport,
    if (traceId != null && traceId!.trim().isNotEmpty) 'trace_id': traceId,
    if (spanId != null && spanId!.trim().isNotEmpty) 'span_id': spanId,
    if (parentSpanId != null && parentSpanId!.trim().isNotEmpty)
      'parent_span_id': parentSpanId,
    'details': details,
  };

  Map<String, Object?> toJson() => {
    'clientEventId': clientEventId,
    'level': level,
    'event': event,
    'message': message,
    'occurredAtUtc': occurredAtUtc.toUtc().toIso8601String(),
    'stack': stack,
    'platform': platform,
    'appVersion': appVersion,
    'sessionId': sessionId,
    'source': source,
    'transport': transport,
    'traceId': traceId,
    'spanId': spanId,
    'parentSpanId': parentSpanId,
    'details': details,
  };

  factory ClientTelemetryEvent.fromJson(Map<String, Object?> json) {
    final details = json['details'];
    return ClientTelemetryEvent(
      clientEventId: json['clientEventId'] as String?,
      level: json['level'] as String? ?? 'info',
      event: json['event'] as String? ?? 'diagnostic',
      message: json['message'] as String? ?? '',
      occurredAtUtc:
          DateTime.tryParse(json['occurredAtUtc'] as String? ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
      stack: json['stack'] as String?,
      platform: json['platform'] as String?,
      appVersion: json['appVersion'] as String?,
      sessionId: json['sessionId'] as String?,
      source: json['source'] as String? ?? 'flutter',
      transport: json['transport'] as String? ?? 'rest_outbox',
      traceId: json['traceId'] as String?,
      spanId: json['spanId'] as String?,
      parentSpanId: json['parentSpanId'] as String?,
      details: details is Map
          ? details.cast<String, Object?>()
          : const <String, Object?>{},
    );
  }

  static String _normalizeId(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? _uuid.v4() : trimmed;
  }
}
