import 'dart:math' as math;

import 'sleep_session.dart';

/// A per-user model of sleep-cycle length learned from recent nights.
///
/// Two things vary between people and are learned here:
///   * the *typical* cycle length (some people run ~75 min, others ~110+); and
///   * how length *drifts across the night* — early cycles are usually shorter
///     (more deep sleep), later cycles longer (more REM). We capture this as a
///     per-position mean ([expectedLengthOfCycle]) so the predicted time of the
///     5th/6th cycle isn't just `n * meanCycle`.
///
/// Built by [SleepCycleProfile.learn] from up to ~35 recent [SleepSession]s with
/// recency weighting; falls back gracefully to [defaultCycleMinutes] before any
/// data exists.
class SleepCycleProfile {
  const SleepCycleProfile({
    required this.overallMeanMinutes,
    required this.perPositionMinutes,
    required this.sampleNights,
    required this.confidence,
    this.defaultCycleMinutes = 90.0,
  });

  /// A cold-start profile with no learned history.
  const SleepCycleProfile.initial({this.defaultCycleMinutes = 90.0})
      : overallMeanMinutes = defaultCycleMinutes,
        perPositionMinutes = const [],
        sampleNights = 0,
        confidence = 0.0;

  /// Weighted mean cycle length across all positions (minutes).
  final double overallMeanMinutes;

  /// Mean length of cycle #1, #2, ... (1-based position → index 0,1,...).
  /// Captures within-night drift. May be shorter than the cycle count seen on
  /// any single night.
  final List<double> perPositionMinutes;

  final int sampleNights;

  /// 0..1 — how much to trust the learned values vs. the default prior.
  final double confidence;

  final double defaultCycleMinutes;

  /// Plausible bounds for a human sleep cycle; estimates are clamped here so a
  /// noisy night can't produce an absurd alarm time.
  static const double minCycleMinutes = 60.0;
  static const double maxCycleMinutes = 130.0;

  /// Expected length (minutes) of the [index]-th cycle (1-based), blending the
  /// learned per-position mean toward the overall mean when that position has
  /// thin data.
  double expectedLengthOfCycle(int index) {
    if (index >= 1 &&
        index <= perPositionMinutes.length &&
        perPositionMinutes[index - 1] > 0) {
      return perPositionMinutes[index - 1]
          .clamp(minCycleMinutes, maxCycleMinutes);
    }
    return overallMeanMinutes.clamp(minCycleMinutes, maxCycleMinutes);
  }

  /// Predicted elapsed minutes from sleep onset to the *end* of the [cycleCount]-th
  /// cycle — i.e. when a smart alarm should aim. With no history this is just
  /// `cycleCount * defaultCycleMinutes` (e.g. 5 × 90 = 450 min = 7.5 h).
  double cumulativeMinutesToEndOfCycle(int cycleCount) {
    var total = 0.0;
    for (var i = 1; i <= cycleCount; i++) {
      total += expectedLengthOfCycle(i);
    }
    return total;
  }

  /// Learn a profile from recent nights (newest-last or any order). Nights with
  /// no measured cycles are ignored. More recent nights weigh more (exponential
  /// recency by night index within [sessions]).
  static SleepCycleProfile learn(
    List<SleepSession> sessions, {
    double defaultCycleMinutes = 90.0,
    double recencyHalfLifeNights = 10.0,
  }) {
    final usable = sessions
        .where((s) => s.cycleLengthsMinutes.any((l) => l > 0))
        .toList()
      ..sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    if (usable.isEmpty) {
      return SleepCycleProfile.initial(defaultCycleMinutes: defaultCycleMinutes);
    }

    final n = usable.length;
    // Weight by recency: the most recent night (last) has weight 1, older nights
    // decay with the given half-life.
    final decay = math.pow(0.5, 1.0 / recencyHalfLifeNights).toDouble();

    var overallSum = 0.0;
    var overallWeight = 0.0;
    final posSum = <double>[];
    final posWeight = <double>[];

    for (var night = 0; night < n; night++) {
      final w = math.pow(decay, (n - 1 - night)).toDouble();
      final lengths = usable[night].cycleLengthsMinutes;
      for (var p = 0; p < lengths.length; p++) {
        final len = lengths[p];
        if (len < minCycleMinutes * 0.5 || len > maxCycleMinutes * 1.5) {
          continue; // discard clearly-bogus measured lengths
        }
        final clamped = len.clamp(minCycleMinutes, maxCycleMinutes);
        overallSum += clamped * w;
        overallWeight += w;
        while (posSum.length <= p) {
          posSum.add(0);
          posWeight.add(0);
        }
        posSum[p] += clamped * w;
        posWeight[p] += w;
      }
    }

    if (overallWeight <= 0) {
      return SleepCycleProfile.initial(defaultCycleMinutes: defaultCycleMinutes);
    }
    final overallMean = overallSum / overallWeight;

    // Per-position mean with shrinkage toward the overall mean for thin positions.
    const shrink = 1.5; // pseudo-nights of overall-mean prior per position
    final perPosition = <double>[];
    for (var p = 0; p < posSum.length; p++) {
      final wsum = posWeight[p];
      final mean = (posSum[p] + shrink * overallMean) / (wsum + shrink);
      perPosition.add(mean);
    }

    // Confidence grows with nights of data, saturating around ~14 nights.
    final confidence = (n / 14.0).clamp(0.0, 1.0);
    return SleepCycleProfile(
      overallMeanMinutes: overallMean,
      perPositionMinutes: perPosition,
      sampleNights: n,
      confidence: confidence,
      defaultCycleMinutes: defaultCycleMinutes,
    );
  }
}
