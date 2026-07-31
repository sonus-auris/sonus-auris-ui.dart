// Value types for multi-signal sleep sensing: user consent flags and a combined sensor+audio sample.
class SleepSignalConsent {
  const SleepSignalConsent({
    this.audio = true,
    this.motion = false,
    this.ambientLight = false,
    this.phoneContext = false,
  });

  final bool audio;
  final bool motion;
  final bool ambientLight;
  final bool phoneContext;
}

class SleepSignalSample {
  const SleepSignalSample({
    this.acousticSleepScore,
    this.acousticArousalScore,
    this.motionStillnessScore,
    this.tossingEventsPerHour,
    this.gotUp = false,
    this.ambientLux,
    this.phoneIdleMinutes,
    this.isCharging,
    this.usualBedtimeScore,
  });

  final double? acousticSleepScore;
  final double? acousticArousalScore;
  final double? motionStillnessScore;
  final double? tossingEventsPerHour;
  final bool gotUp;
  final double? ambientLux;
  final double? phoneIdleMinutes;
  final bool? isCharging;
  final double? usualBedtimeScore;
}

class SleepProbabilityEstimate {
  const SleepProbabilityEstimate({
    required this.sleepProbability,
    required this.wakeProbability,
    required this.activeSignals,
  });

  final double sleepProbability;
  final double wakeProbability;
  final List<String> activeSignals;

  bool get likelyAsleep => sleepProbability >= 0.65;
}

class SleepProbabilityModel {
  const SleepProbabilityModel();

  SleepProbabilityEstimate estimate({
    required SleepSignalSample sample,
    required SleepSignalConsent consent,
  }) {
    var weighted = 0.0;
    var totalWeight = 0.0;
    final active = <String>[];

    double? usable(double? value) =>
        value != null && value.isFinite ? value : null;

    void add(String signal, double score, double weight) {
      if (!score.isFinite || !weight.isFinite || weight <= 0) {
        return;
      }
      weighted += score.clamp(0.0, 1.0) * weight;
      totalWeight += weight;
      active.add(signal);
    }

    final acousticSleep = usable(sample.acousticSleepScore);
    if (consent.audio && acousticSleep != null) {
      final sleep = acousticSleep.clamp(0.0, 1.0);
      final arousal =
          usable(sample.acousticArousalScore)?.clamp(0.0, 1.0) ?? 0.0;
      add('audio', (sleep * 0.78 + (1.0 - arousal) * 0.22), 0.42);
    }

    final motionStillness = usable(sample.motionStillnessScore);
    if (consent.motion && motionStillness != null) {
      final stillness = motionStillness.clamp(0.0, 1.0);
      final tossingPenalty =
          ((usable(sample.tossingEventsPerHour) ?? 0.0) / 12.0).clamp(0.0, 1.0);
      final gotUpPenalty = sample.gotUp ? 0.45 : 0.0;
      add('motion', stillness - tossingPenalty * 0.35 - gotUpPenalty, 0.26);
    }

    final ambientLux = usable(sample.ambientLux);
    if (consent.ambientLight && ambientLux != null) {
      final darkness = (1.0 - (ambientLux / 60.0)).clamp(0.0, 1.0);
      add('ambientLight', darkness, 0.16);
    }

    if (consent.phoneContext) {
      var contextWeighted = 0.0;
      var contextWeight = 0.0;
      final idle = usable(sample.phoneIdleMinutes);
      if (idle != null) {
        contextWeighted += (idle / 45.0).clamp(0.0, 1.0) * 0.45;
        contextWeight += 0.45;
      }
      final charging = sample.isCharging;
      if (charging != null) {
        contextWeighted += (charging ? 1.0 : 0.25) * 0.20;
        contextWeight += 0.20;
      }
      final bedtime = usable(sample.usualBedtimeScore);
      if (bedtime != null) {
        contextWeighted += bedtime.clamp(0.0, 1.0) * 0.35;
        contextWeight += 0.35;
      }
      if (contextWeight > 0) {
        add('phoneContext', contextWeighted / contextWeight, 0.16);
      }
    }

    if (totalWeight == 0) {
      return const SleepProbabilityEstimate(
        sleepProbability: 0.0,
        wakeProbability: 1.0,
        activeSignals: [],
      );
    }

    final probability = (weighted / totalWeight).clamp(0.0, 1.0).toDouble();
    return SleepProbabilityEstimate(
      sleepProbability: probability,
      wakeProbability: 1.0 - probability,
      activeSignals: active,
    );
  }
}
