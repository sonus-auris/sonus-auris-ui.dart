import 'sleep_stage.dart';

/// One fixed-length window (default 30 s) of aggregated sleep features produced
/// by the sleep engine. A night is a sequence of these. All fields are derived
/// purely from the on-device FFT [SpectralFrame] stream plus the snore detector,
/// so an epoch is JSON-serializable and contains no raw audio.
class SleepEpoch {
  const SleepEpoch({
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.meanDb,
    required this.movement,
    required this.snoreFraction,
    required this.breathingRateBpm,
    required this.breathingRegularity,
    required this.depth,
    required this.stage,
  });

  final DateTime startedAtUtc;
  final DateTime endedAtUtc;

  /// Mean loudness across the epoch in dBFS (quieter == lower).
  final double meanDb;

  /// Movement/arousal energy 0..1: fraction of the epoch with loud transients
  /// above the rolling quiet baseline (rustling, rolling over, getting up).
  final double movement;

  /// Fraction of the epoch covered by detected snore episodes, 0..1.
  final double snoreFraction;

  /// Estimated respiratory rate in breaths/min from the low-band amplitude
  /// modulation (0 when no periodic breathing envelope was found).
  final double breathingRateBpm;

  /// How periodic/steady the breathing envelope is, 0..1 (1 == metronomic).
  final double breathingRegularity;

  /// Relative sleep depth 0..1 (1 == deepest slow-wave-like state). This is the
  /// smoothed signal the cycle detector tracks; cycle boundaries are its troughs.
  final double depth;

  final SleepStage stage;

  Duration get duration => endedAtUtc.difference(startedAtUtc);

  Map<String, dynamic> toJson() => {
        'startedAtUtc': startedAtUtc.toIso8601String(),
        'endedAtUtc': endedAtUtc.toIso8601String(),
        'meanDb': meanDb,
        'movement': movement,
        'snoreFraction': snoreFraction,
        'breathingRateBpm': breathingRateBpm,
        'breathingRegularity': breathingRegularity,
        'depth': depth,
        'stage': stage.name,
      };

  factory SleepEpoch.fromJson(Map<String, dynamic> json) {
    return SleepEpoch(
      startedAtUtc: DateTime.parse(json['startedAtUtc'] as String).toUtc(),
      endedAtUtc: DateTime.parse(json['endedAtUtc'] as String).toUtc(),
      meanDb: _d(json['meanDb']),
      movement: _d(json['movement']),
      snoreFraction: _d(json['snoreFraction']),
      breathingRateBpm: _d(json['breathingRateBpm']),
      breathingRegularity: _d(json['breathingRegularity']),
      depth: _d(json['depth']),
      stage: SleepStage.fromName(json['stage'] as String?),
    );
  }

  static double _d(Object? v) =>
      v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0;
}
