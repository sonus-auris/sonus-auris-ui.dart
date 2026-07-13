// Reads native motion / ambient-light / phone-context sensors (via method channel) as extra sleep-sensing signals.
import 'package:flutter/services.dart';

class SleepSensorSnapshot {
  const SleepSensorSnapshot({
    required this.sampledAtUtc,
    this.motionStillnessScore,
    this.ambientLux,
    this.screenBrightness,
    this.motionAvailable = false,
    this.ambientLightAvailable = false,
  });

  final DateTime sampledAtUtc;
  final double? motionStillnessScore;
  final double? ambientLux;
  final double? screenBrightness;
  final bool motionAvailable;
  final bool ambientLightAvailable;

  factory SleepSensorSnapshot.fromMap(Map<dynamic, dynamic> map) {
    return SleepSensorSnapshot(
      sampledAtUtc: DateTime.fromMillisecondsSinceEpoch(
        _asInt(map['sampledAtMillis'], DateTime.now().millisecondsSinceEpoch),
        isUtc: true,
      ),
      motionStillnessScore: _nullableDouble(map['motionStillnessScore']),
      ambientLux: _nullableDouble(map['ambientLux']),
      screenBrightness: _nullableDouble(map['screenBrightness']),
      motionAvailable: map['motionAvailable'] as bool? ?? false,
      ambientLightAvailable: map['ambientLightAvailable'] as bool? ?? false,
    );
  }

  SleepSignalValues toSignalValues() {
    return SleepSignalValues(
      motionStillnessScore: motionAvailable ? motionStillnessScore : null,
      ambientLux: ambientLightAvailable ? ambientLux : null,
    );
  }

  static int _asInt(Object? value, int fallback) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static double? _nullableDouble(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString());
  }
}

class SleepSignalValues {
  const SleepSignalValues({this.motionStillnessScore, this.ambientLux});

  final double? motionStillnessScore;
  final double? ambientLux;
}

class SleepSensorService {
  SleepSensorService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('audio_dashcam/sleep_sensors');

  final MethodChannel _channel;

  Future<SleepSensorSnapshot> sample({
    required bool motionConsent,
    required bool ambientLightConsent,
  }) async {
    if (!motionConsent && !ambientLightConsent) {
      return SleepSensorSnapshot(sampledAtUtc: DateTime.now().toUtc());
    }
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'sampleSleepSignals',
      {'motion': motionConsent, 'ambientLight': ambientLightConsent},
    );
    return SleepSensorSnapshot.fromMap(raw ?? const {});
  }
}
