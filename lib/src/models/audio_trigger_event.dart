// An audio-derived trigger (loud commotion, spoken magic phrase, or a manual mark) reported to the backend.
class AudioTriggerEvent {
  const AudioTriggerEvent({
    required this.type,
    required this.occurredAtUtc,
    required this.captureSessionId,
    required this.sampleIndex,
    this.averagePower = 0,
    this.peakPower = 0,
    this.phrase,
  });

  final AudioTriggerType type;
  final DateTime occurredAtUtc;
  final String captureSessionId;
  final int sampleIndex;
  final double averagePower;
  final double peakPower;
  final String? phrase;

  String get serverTrigger {
    switch (type) {
      case AudioTriggerType.commotion:
        return 'commotion';
      case AudioTriggerType.magicPhrase:
        return 'magic_phrase';
      case AudioTriggerType.manual:
        return 'manual';
    }
  }

  Map<String, Object?> get metadata {
    return {
      'captureSessionId': captureSessionId,
      'sampleIndex': sampleIndex,
      'averagePower': averagePower,
      'peakPower': peakPower,
      if (phrase != null) 'phrase': phrase,
    };
  }

  Map<String, Object?> toJson() {
    return {
      'type': type.name,
      'occurredAtUtc': occurredAtUtc.toIso8601String(),
      'captureSessionId': captureSessionId,
      'sampleIndex': sampleIndex,
      'averagePower': averagePower,
      'peakPower': peakPower,
      'phrase': phrase,
    };
  }

  factory AudioTriggerEvent.fromJson(Map<String, dynamic> json) {
    return AudioTriggerEvent(
      type: AudioTriggerType.fromName(json['type'] as String?),
      occurredAtUtc: DateTime.parse(json['occurredAtUtc'] as String).toUtc(),
      captureSessionId: json['captureSessionId'] as String? ?? '',
      sampleIndex: _asInt(json['sampleIndex']),
      averagePower: _asDouble(json['averagePower']),
      peakPower: _asDouble(json['peakPower']),
      phrase: json['phrase'] as String?,
    );
  }

  static int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
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

enum AudioTriggerType {
  commotion,
  magicPhrase,
  manual;

  static AudioTriggerType fromName(String? name) {
    return AudioTriggerType.values.firstWhere(
      (type) => type.name == name,
      orElse: () => AudioTriggerType.manual,
    );
  }
}
