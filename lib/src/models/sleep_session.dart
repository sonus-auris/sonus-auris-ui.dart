import 'sleep_cycle.dart';

/// A persisted summary of one night's sleep. We keep the *summary* (cycle
/// lengths, the FFT-derived dominant period, a coarse depth envelope for charts)
/// rather than the full per-epoch stream, so 35 nights stay tiny on disk and
/// contain no audio. These records feed the per-user cycle-length learning in
/// [SleepCycleProfile].
class SleepSession {
  const SleepSession({
    required this.id,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.cycles,
    required this.dominantCycleMinutes,
    this.depthEnvelope = const [],
    this.envelopeStepMinutes = 5.0,
  });

  final String id;
  final DateTime startedAtUtc;

  /// End of the session (wake / stop). May equal [startedAtUtc] for an empty
  /// session that never produced epochs.
  final DateTime endedAtUtc;

  /// Completed cycles in chronological order.
  final List<SleepCycle> cycles;

  /// Dominant cycle length for the night estimated by FFT periodicity over the
  /// depth envelope (minutes). 0 when not enough data.
  final double dominantCycleMinutes;

  /// Coarse depth samples (0..1), one every [envelopeStepMinutes], for charts.
  final List<double> depthEnvelope;
  final double envelopeStepMinutes;

  /// Local calendar date the night is filed under (the date sleep *started*).
  DateTime get nightLocalDate {
    final local = startedAtUtc.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  double get totalMinutes =>
      endedAtUtc.difference(startedAtUtc).inMilliseconds / 60000.0;

  /// Measured cycle lengths in order (minutes) — the learning input.
  List<double> get cycleLengthsMinutes =>
      cycles.map((c) => c.lengthMinutes).toList(growable: false);

  Map<String, dynamic> toJson() => {
        'id': id,
        'startedAtUtc': startedAtUtc.toIso8601String(),
        'endedAtUtc': endedAtUtc.toIso8601String(),
        'cycles': cycles.map((c) => c.toJson()).toList(),
        'dominantCycleMinutes': dominantCycleMinutes,
        'depthEnvelope': depthEnvelope,
        'envelopeStepMinutes': envelopeStepMinutes,
      };

  factory SleepSession.fromJson(Map<String, dynamic> json) {
    return SleepSession(
      id: json['id'] as String? ?? '',
      startedAtUtc: DateTime.parse(json['startedAtUtc'] as String).toUtc(),
      endedAtUtc: DateTime.parse(json['endedAtUtc'] as String).toUtc(),
      cycles: ((json['cycles'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(SleepCycle.fromJson)
          .toList(),
      dominantCycleMinutes:
          (json['dominantCycleMinutes'] as num?)?.toDouble() ?? 0,
      depthEnvelope: ((json['depthEnvelope'] as List?) ?? const [])
          .map((e) => (e as num).toDouble())
          .toList(),
      envelopeStepMinutes:
          (json['envelopeStepMinutes'] as num?)?.toDouble() ?? 5.0,
    );
  }
}
