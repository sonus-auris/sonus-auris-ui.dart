/// A single raw reading from the optional sleep sensors (accelerometer / ambient
/// light). Every field is opt-in and may be null when the user hasn't granted
/// express consent for that sensor or the platform doesn't expose it (e.g. iOS
/// has no public ambient-light API).
class SleepSensorSample {
  const SleepSensorSample({
    required this.atUtc,
    this.accelMagnitude,
    this.lux,
  });

  final DateTime atUtc;

  /// Linear-acceleration magnitude in m/s² with gravity removed (0 == perfectly
  /// still). Spikes mark movement: tossing, turning, getting up. Null when the
  /// motion sensor is off.
  final double? accelMagnitude;

  /// Ambient illuminance in lux. Low for a dark bedroom; rises at dawn / lights
  /// on. Null when the light sensor is off or unavailable.
  final double? lux;
}

/// Per-epoch aggregate of [SleepSensorSample]s, lined up with one acoustic sleep
/// epoch so the two streams fuse cleanly.
class SleepSensorEpoch {
  const SleepSensorEpoch({
    required this.movement,
    required this.meanLux,
    required this.hasMotion,
    required this.hasLight,
    required this.sampleCount,
  });

  const SleepSensorEpoch.empty()
      : movement = 0.0,
        meanLux = null,
        hasMotion = false,
        hasLight = false,
        sampleCount = 0;

  /// 0..1 movement energy over the epoch (fraction of samples above the
  /// stillness threshold, scaled by intensity). 0 when no motion sensor.
  final double movement;

  /// Mean illuminance over the epoch (lux), or null when no light sensor.
  final double? meanLux;

  final bool hasMotion;
  final bool hasLight;
  final int sampleCount;

  /// Dark enough to look like a bedroom at night (only meaningful when [hasLight]).
  bool get isDark => meanLux != null && meanLux! <= 5.0;
}
