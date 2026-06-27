/// One completed (or in-progress) sleep cycle: the descent into deep sleep and
/// the climb back out to a light/REM arousal that ends it. [index] is 1-based
/// (the first cycle of the night is cycle 1).
class SleepCycle {
  const SleepCycle({
    required this.index,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.minDepth,
    required this.maxDepth,
  });

  final int index;
  final DateTime startedAtUtc;
  final DateTime endedAtUtc;

  /// Shallowest depth reached (near the boundary).
  final double minDepth;

  /// Deepest depth reached within the cycle.
  final double maxDepth;

  double get lengthMinutes =>
      endedAtUtc.difference(startedAtUtc).inMilliseconds / 60000.0;

  Map<String, dynamic> toJson() => {
        'index': index,
        'startedAtUtc': startedAtUtc.toIso8601String(),
        'endedAtUtc': endedAtUtc.toIso8601String(),
        'minDepth': minDepth,
        'maxDepth': maxDepth,
      };

  factory SleepCycle.fromJson(Map<String, dynamic> json) {
    return SleepCycle(
      index: (json['index'] as num?)?.toInt() ?? 0,
      startedAtUtc: DateTime.parse(json['startedAtUtc'] as String).toUtc(),
      endedAtUtc: DateTime.parse(json['endedAtUtc'] as String).toUtc(),
      minDepth: (json['minDepth'] as num?)?.toDouble() ?? 0,
      maxDepth: (json['maxDepth'] as num?)?.toDouble() ?? 0,
    );
  }
}
