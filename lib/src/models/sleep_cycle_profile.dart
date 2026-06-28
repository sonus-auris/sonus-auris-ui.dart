import 'acoustic_detection.dart';

class SleepCycleObservation {
  const SleepCycleObservation({
    required this.endedAtUtc,
    required this.cycleIndex,
    required this.observedCycleMinutes,
    required this.estimatedCycleMinutes,
    required this.cycleMinutesByIndex,
  });

  final DateTime endedAtUtc;
  final int cycleIndex;
  final double observedCycleMinutes;
  final double estimatedCycleMinutes;
  final List<double> cycleMinutesByIndex;

  Map<String, dynamic> toJson() {
    return {
      'endedAtUtc': endedAtUtc.toIso8601String(),
      'cycleIndex': cycleIndex,
      'observedCycleMinutes': observedCycleMinutes,
      'estimatedCycleMinutes': estimatedCycleMinutes,
      'cycleMinutesByIndex': cycleMinutesByIndex,
    };
  }

  factory SleepCycleObservation.fromJson(Map<String, dynamic> json) {
    return SleepCycleObservation(
      endedAtUtc:
          _asUtc(json['endedAtUtc']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      cycleIndex: _asInt(json['cycleIndex'], 0),
      observedCycleMinutes: _asDouble(json['observedCycleMinutes'], 90),
      estimatedCycleMinutes: _asDouble(json['estimatedCycleMinutes'], 90),
      cycleMinutesByIndex: _asDoubleList(json['cycleMinutesByIndex']),
    );
  }

  static SleepCycleObservation? fromDetection(AcousticDetection detection) {
    if (detection.kind != AcousticDetectionKind.sleepCycle &&
        detection.kind != AcousticDetectionKind.sleepCycleAlarm) {
      return null;
    }
    final details = detection.details;
    final cycleIndex = _asInt(details['cycleIndex'], 0);
    final observed = details['observedCycleMinutes'];
    if (cycleIndex <= 0 || observed == null) {
      return null;
    }
    return SleepCycleObservation(
      endedAtUtc: detection.endedAtUtc.toUtc(),
      cycleIndex: cycleIndex,
      observedCycleMinutes: _asDouble(observed, 90),
      estimatedCycleMinutes: _asDouble(details['estimatedCycleMinutes'], 90),
      cycleMinutesByIndex: _asDoubleList(details['cycleMinutesByIndex']),
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

  static double _asDouble(Object? value, double fallback) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static DateTime? _asUtc(Object? value) {
    if (value is! String) {
      return null;
    }
    return DateTime.tryParse(value)?.toUtc();
  }

  static List<double> _asDoubleList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return value
        .map((entry) => _asDouble(entry, 90).clamp(75.0, 120.0).toDouble())
        .where((entry) => entry.isFinite)
        .take(12)
        .toList(growable: false);
  }
}

class SleepCycleProfile {
  const SleepCycleProfile({this.observations = const []});

  static const int historyWindowDays = 35;
  static const double fallbackCycleMinutes = 90.0;

  final List<SleepCycleObservation> observations;

  SleepCycleProfile addObservation(SleepCycleObservation observation) {
    return SleepCycleProfile(
      observations: [...observations, observation],
    ).pruned(observation.endedAtUtc);
  }

  SleepCycleProfile pruned(DateTime nowUtc) {
    final cutoff = nowUtc.toUtc().subtract(
      const Duration(days: historyWindowDays),
    );
    final kept = observations
        .where((observation) => !observation.endedAtUtc.isBefore(cutoff))
        .toList(growable: false);
    return SleepCycleProfile(observations: kept);
  }

  List<double> cycleMinuteSeeds({int maxCycles = 6}) {
    final seeds = <double>[];
    for (var cycle = 1; cycle <= maxCycles; cycle++) {
      final values = observations
          .where((observation) => observation.cycleIndex == cycle)
          .map((observation) => observation.observedCycleMinutes)
          .where((minutes) => minutes >= 75.0 && minutes <= 120.0)
          .toList(growable: false);
      if (values.isNotEmpty) {
        seeds.add(_weightedAverage(values));
        continue;
      }
      final latestVector = _latestCycleVectorValue(cycle);
      if (latestVector != null) {
        seeds.add(latestVector);
      } else if (seeds.isNotEmpty) {
        seeds.add(seeds.last);
      } else {
        seeds.add(fallbackCycleMinutes);
      }
    }
    return seeds
        .map((minutes) => minutes.clamp(75.0, 120.0).toDouble())
        .toList(growable: false);
  }

  Map<String, dynamic> toJson() {
    return {
      'observations': observations.map((observation) {
        return observation.toJson();
      }).toList(),
    };
  }

  factory SleepCycleProfile.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const SleepCycleProfile();
    }
    final raw = json['observations'];
    if (raw is! List) {
      return const SleepCycleProfile();
    }
    final observations = <SleepCycleObservation>[];
    for (final entry in raw) {
      if (entry is! Map) {
        continue;
      }
      try {
        final observation = SleepCycleObservation.fromJson(
          entry.cast<String, dynamic>(),
        );
        if (observation.endedAtUtc.millisecondsSinceEpoch > 0 &&
            observation.cycleIndex > 0) {
          observations.add(observation);
        }
      } catch (_) {
        continue;
      }
    }
    return SleepCycleProfile(
      observations: observations.toList(growable: false),
    );
  }

  double? _latestCycleVectorValue(int cycleIndex) {
    for (final observation in observations.reversed) {
      final vector = observation.cycleMinutesByIndex;
      if (cycleIndex > 0 && cycleIndex <= vector.length) {
        return vector[cycleIndex - 1];
      }
    }
    return null;
  }

  static double _weightedAverage(List<double> values) {
    var weighted = 0.0;
    var totalWeight = 0.0;
    for (var i = 0; i < values.length; i++) {
      final weight = i + 1.0;
      weighted += values[i] * weight;
      totalWeight += weight;
    }
    return weighted / totalWeight;
  }
}
