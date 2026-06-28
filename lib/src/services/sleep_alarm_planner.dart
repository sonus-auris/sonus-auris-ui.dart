import '../models/sleep_cycle_profile.dart';
import '../models/sleep_stage.dart';

/// What the alarm engine wants to do right now.
enum SleepAlarmDecision {
  /// Stay asleep — either too early, or in deep sleep within the smart window
  /// (we hold off and wait for the next light arousal).
  hold,

  /// Wake now: we're at/after the target-cycle window AND in a light/REM/awake
  /// state (a good moment to wake).
  smartWake,

  /// Hard backstop wake: we reached the end of the backstop cycle (≈9 h) without
  /// finding a light-sleep window, so wake regardless of stage.
  backstopWake,
}

/// Predicted alarm timing for a session, in absolute UTC.
class SleepAlarmPlan {
  const SleepAlarmPlan({
    required this.onsetUtc,
    required this.smartWindowStartUtc,
    required this.targetTimeUtc,
    required this.backstopTimeUtc,
  });

  final DateTime onsetUtc;

  /// Earliest the smart wake may fire (target − smart window).
  final DateTime smartWindowStartUtc;

  /// Predicted end of the target cycle (the ideal wake moment, ≈7.5 h default).
  final DateTime targetTimeUtc;

  /// Predicted end of the backstop cycle (the hard wake deadline, ≈9 h default).
  final DateTime backstopTimeUtc;
}

/// Pure decision core for cycle-aware ("smart") alarms.
///
/// Behaviour (the product spec):
///   * Aim to wake the sleeper at the end of the *target* cycle (5th ≈ 7.5 h).
///   * But **never wake during deep sleep**: from `target − smartWindow` onward,
///     only fire at a light/REM/awake arousal. If the sleeper is in deep sleep
///     at cycle 5, hold off and wait for the next light window…
///   * …up to a hard **backstop** at the end of the *backstop* cycle (6th ≈ 9 h),
///     where we wake regardless of stage.
///
/// Stateless: feed it the current observation; the caller tracks "already fired".
class SleepAlarmPlanner {
  const SleepAlarmPlanner();

  /// Builds the timing plan, blending cycles already *measured* tonight with the
  /// learned [profile] for the cycles still to come. As real cycles complete the
  /// caller re-plans, so the prediction sharpens through the night.
  SleepAlarmPlan plan({
    required DateTime onsetUtc,
    required List<double> measuredCycleMinutes,
    required SleepCycleProfile profile,
    required int targetCycle,
    required int backstopCycle,
    required double smartWindowMinutes,
  }) {
    final targetMin =
        predictedCumulativeMinutes(targetCycle, measuredCycleMinutes, profile);
    final backstopMin =
        predictedCumulativeMinutes(backstopCycle, measuredCycleMinutes, profile);
    final targetTime =
        onsetUtc.add(Duration(milliseconds: (targetMin * 60000).round()));
    final backstopTime =
        onsetUtc.add(Duration(milliseconds: (backstopMin * 60000).round()));
    final windowStart = targetTime
        .subtract(Duration(milliseconds: (smartWindowMinutes * 60000).round()));
    return SleepAlarmPlan(
      onsetUtc: onsetUtc,
      smartWindowStartUtc:
          windowStart.isBefore(onsetUtc) ? onsetUtc : windowStart,
      targetTimeUtc: targetTime,
      backstopTimeUtc:
          backstopTime.isAfter(targetTime) ? backstopTime : targetTime,
    );
  }

  /// Decide what to do at [nowUtc] given the current [stage] and how many cycles
  /// have completed.
  SleepAlarmDecision evaluate({
    required SleepAlarmPlan plan,
    required DateTime nowUtc,
    required bool smartAlarmEnabled,
    required SleepStage stage,
    required int cyclesCompleted,
    required int targetCycle,
    required int backstopCycle,
  }) {
    // The single feature toggle: when off, no sleep alarm fires at all (the
    // caller also skips scheduling the OS backstop, so this stays consistent).
    if (!smartAlarmEnabled) {
      return SleepAlarmDecision.hold;
    }

    // Hard backstop: reached the 6th-cycle deadline (by time or by count).
    final hitBackstopTime = !nowUtc.isBefore(plan.backstopTimeUtc);
    final hitBackstopCount = cyclesCompleted >= backstopCycle;
    if (hitBackstopTime || hitBackstopCount) {
      return SleepAlarmDecision.backstopWake;
    }

    // Inside the smart window?
    if (nowUtc.isBefore(plan.smartWindowStartUtc)) {
      return SleepAlarmDecision.hold;
    }

    // Require that we're at least nearly through the target cycles, so an early
    // light patch (if predictions run short) can't trigger a premature wake.
    if (cyclesCompleted < targetCycle - 1) {
      return SleepAlarmDecision.hold;
    }

    // The core rule: only wake in a shallow state. Deep sleep → hold and wait
    // for the next light/REM/awake arousal (bounded by the backstop above).
    if (stage.isShallow) {
      return SleepAlarmDecision.smartWake;
    }
    return SleepAlarmDecision.hold;
  }

  /// Predicted elapsed minutes from onset to the end of the [n]-th cycle. Uses
  /// the lengths already measured tonight for the first cycles and the learned
  /// [profile] for the rest.
  static double predictedCumulativeMinutes(
    int n,
    List<double> measured,
    SleepCycleProfile profile,
  ) {
    var total = 0.0;
    for (var i = 1; i <= n; i++) {
      if (i <= measured.length && measured[i - 1] > 0) {
        total += measured[i - 1].clamp(
          SleepCycleProfile.minCycleMinutes,
          SleepCycleProfile.maxCycleMinutes,
        );
      } else {
        total += profile.expectedLengthOfCycle(i);
      }
    }
    return total;
  }
}
