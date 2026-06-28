/// A single acoustic event recognized by the on-device FFT analysis engine.
///
/// These are *non-diagnostic* heuristic detections. In particular [apneaPattern]
/// describes a breathing-cessation-like acoustic pattern and is explicitly not a
/// medical diagnosis. Events are surfaced in-app and synced to Supabase.
class AcousticDetection {
  const AcousticDetection({
    required this.kind,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.confidence,
    this.captureSessionId = '',
    this.details = const {},
  });

  final AcousticDetectionKind kind;
  final DateTime startedAtUtc;
  final DateTime endedAtUtc;

  /// Heuristic confidence in 0..1.
  final double confidence;

  final String captureSessionId;

  /// Kind-specific extras: song title/artist, matched keyword, gap seconds,
  /// dominant frequency, etc. JSON-serializable values only.
  final Map<String, Object?> details;

  Duration get duration => endedAtUtc.difference(startedAtUtc);

  AcousticDetection copyWith({
    AcousticDetectionKind? kind,
    DateTime? startedAtUtc,
    DateTime? endedAtUtc,
    double? confidence,
    String? captureSessionId,
    Map<String, Object?>? details,
  }) {
    return AcousticDetection(
      kind: kind ?? this.kind,
      startedAtUtc: startedAtUtc ?? this.startedAtUtc,
      endedAtUtc: endedAtUtc ?? this.endedAtUtc,
      confidence: confidence ?? this.confidence,
      captureSessionId: captureSessionId ?? this.captureSessionId,
      details: details ?? this.details,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'kind': kind.name,
      'startedAtUtc': startedAtUtc.toIso8601String(),
      'endedAtUtc': endedAtUtc.toIso8601String(),
      'confidence': confidence,
      'captureSessionId': captureSessionId,
      'details': details,
    };
  }

  factory AcousticDetection.fromJson(Map<String, dynamic> json) {
    return AcousticDetection(
      kind: AcousticDetectionKind.fromName(json['kind'] as String?),
      startedAtUtc: DateTime.parse(json['startedAtUtc'] as String).toUtc(),
      endedAtUtc: DateTime.parse(json['endedAtUtc'] as String).toUtc(),
      confidence: _asDouble(json['confidence']),
      captureSessionId: json['captureSessionId'] as String? ?? '',
      details: (json['details'] as Map?)?.cast<String, Object?>() ?? const {},
    );
  }

  /// Row shape for the Supabase `acoustic_events` table. [deviceId] ties the
  /// event to this install; the authed user is resolved server-side from the
  /// access token (RLS `auth.uid()`), so no user id is sent from the client.
  Map<String, dynamic> toSupabaseRow(String deviceId) {
    return {
      'device_id': deviceId,
      'kind': kind.name,
      'started_at': startedAtUtc.toIso8601String(),
      'ended_at': endedAtUtc.toIso8601String(),
      'confidence': confidence,
      'details': details,
    };
  }

  static double _asDouble(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}

enum AcousticDetectionKind {
  snore,
  apneaPattern,
  music,
  speech,
  keyword,

  /// One aggregated sleep epoch (~30 s): carries the epoch's depth/stage/features
  /// in [details]. Emitted continuously while a sleep session is active.
  sleepEpoch,

  /// A completed sleep cycle boundary: [details] carries `cycleIndex`,
  /// `lengthMinutes`, and the detected `dominantCycleMinutes`. Drives the
  /// cycle-aware alarm.
  sleepCycle;

  static AcousticDetectionKind fromName(String? name) {
    return AcousticDetectionKind.values.firstWhere(
      (kind) => kind.name == name,
      orElse: () => AcousticDetectionKind.speech,
    );
  }

  /// Human-readable label for the UI.
  String get label {
    switch (this) {
      case AcousticDetectionKind.snore:
        return 'Snoring';
      case AcousticDetectionKind.apneaPattern:
        return 'Possible apnea pattern';
      case AcousticDetectionKind.music:
        return 'Music';
      case AcousticDetectionKind.speech:
        return 'Speech';
      case AcousticDetectionKind.keyword:
        return 'Keyword';
      case AcousticDetectionKind.sleepEpoch:
        return 'Sleep epoch';
      case AcousticDetectionKind.sleepCycle:
        return 'Sleep cycle';
    }
  }
}
