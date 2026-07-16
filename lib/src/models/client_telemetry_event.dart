class ClientTelemetryEvent {
  const ClientTelemetryEvent({
    required this.level,
    required this.event,
    required this.message,
    required this.occurredAtUtc,
    this.stack,
    this.platform,
    this.appVersion,
    this.details = const {},
  });

  final String level;
  final String event;
  final String message;
  final DateTime occurredAtUtc;
  final String? stack;
  final String? platform;
  final String? appVersion;
  final Map<String, Object?> details;

  Map<String, Object?> toSupabaseRow(String deviceId) => {
    'device_id': deviceId,
    'level': level,
    'event': event,
    'message': message,
    'occurred_at': occurredAtUtc.toIso8601String(),
    if (stack != null && stack!.trim().isNotEmpty) 'stack': stack,
    if (platform != null && platform!.trim().isNotEmpty) 'platform': platform,
    if (appVersion != null && appVersion!.trim().isNotEmpty)
      'app_version': appVersion,
    'details': details,
  };
}
