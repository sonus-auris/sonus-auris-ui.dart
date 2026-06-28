import 'dart:math' as math;

import '../models/sleep_sensor_sample.dart';
import '../models/sleep_stage.dart';

/// Non-acoustic context for the sleep-probability model. All optional; the model
/// degrades gracefully as signals drop out.
class SleepFusionContext {
  const SleepFusionContext({
    this.charging,
    this.withinUsualSleepWindow,
    this.minutesSincePhoneInteraction,
  });

  /// Phone plugged in (charging overnight is a sleep cue). Null == unknown.
  final bool? charging;

  /// Whether the current time falls inside the user's usual bedtime window
  /// (learned from past sessions). Null == unknown.
  final bool? withinUsualSleepWindow;

  /// Minutes since the screen was last interacted with. Null == unknown.
  final double? minutesSincePhoneInteraction;
}

/// Output of the fusion: the probabilistic sleep/wake estimate plus the refined
/// depth and stage that drive cycle detection and the smart alarm.
class SleepEstimate {
  const SleepEstimate({
    required this.sleepProbability,
    required this.fusedDepth,
    required this.fusedStage,
  });

  /// 0..1 probability the user is asleep right now.
  final double sleepProbability;

  /// Acoustic depth refined with motion/light (0..1, higher == deeper).
  final double fusedDepth;

  /// Final stage after fusion (motion/light can promote to [SleepStage.awake]).
  final SleepStage fusedStage;
}

/// Pure probabilistic sensor-fusion model.
///
/// Combines the on-device FFT sleep depth/stage with the optional, consent-gated
/// accelerometer and ambient-light sensors and lightweight context ("plugged in
/// + dark room + no phone use + usual bedtime") into:
///   * a **sleep probability** (the "are they asleep" segmenter), and
///   * a **fused depth + stage** used to find cycles and to decide whether the
///     smart alarm may fire (it only fires in a light/REM/awake state).
///
/// Evidence is combined in log-odds (a small naive-Bayes-style model), which is
/// the principled way to fuse independent weak signals. Deterministic and
/// dependency-free, so it's fully unit-testable.
class SleepProbabilityModel {
  const SleepProbabilityModel({
    this.deepThreshold = 0.62,
    this.remRegularityMax = 0.45,
    this.awakeMovement = 0.45,
    this.brightLux = 40.0,
  });

  final double deepThreshold;
  final double remRegularityMax;

  /// Per-epoch sensor movement above which the sleeper is treated as awake.
  final double awakeMovement;

  /// Illuminance above which the room is "bright" (lights on / morning).
  final double brightLux;

  SleepEstimate fuse({
    required double acousticDepth,
    required SleepStage acousticStage,
    required double breathingRegularity,
    required double snoreFraction,
    SleepSensorEpoch sensors = const SleepSensorEpoch.empty(),
    SleepFusionContext context = const SleepFusionContext(),
  }) {
    // --- Sleep probability via additive log-odds ---
    var logit = 0.0;

    // Acoustic depth: centred at 0.5, ±~2 logits across the range.
    logit += (acousticDepth - 0.4) * 4.0;
    if (acousticStage == SleepStage.awake) {
      logit -= 1.5;
    }

    if (sensors.hasMotion) {
      // Stillness strongly favours sleep; movement strongly against.
      logit += (0.35 - sensors.movement) * 6.0;
    }
    if (sensors.hasLight) {
      if (sensors.isDark) {
        logit += 1.0;
      } else if ((sensors.meanLux ?? 0) >= brightLux) {
        logit -= 2.0;
      }
    }
    final charging = context.charging;
    if (charging != null) {
      logit += charging ? 0.6 : -0.2;
    }
    final usual = context.withinUsualSleepWindow;
    if (usual != null) {
      logit += usual ? 0.8 : -0.8;
    }
    final sinceUse = context.minutesSincePhoneInteraction;
    if (sinceUse != null) {
      // Recent phone use argues awake; an hour untouched argues asleep.
      logit += (sinceUse.clamp(0, 60) / 60.0 - 0.5) * 2.0;
    }

    final sleepProbability = _sigmoid(logit);

    // --- Fused depth: refine acoustic depth with motion stillness + darkness ---
    var fusedDepth = acousticDepth;
    if (sensors.hasMotion) {
      final stillness = (1 - sensors.movement).clamp(0.0, 1.0);
      fusedDepth = acousticDepth * 0.65 + stillness * 0.35;
      // A clear movement burst can't coexist with deep sleep.
      if (sensors.movement >= awakeMovement) {
        fusedDepth = math.min(fusedDepth, 0.25);
      }
    }
    if (sensors.hasLight && !sensors.isDark) {
      fusedDepth = math.min(fusedDepth, 0.35); // lit room => not deep
    }
    fusedDepth = fusedDepth.clamp(0.0, 1.0);

    // --- Fused stage ---
    final fusedStage = _stage(
      fusedDepth: fusedDepth,
      acousticStage: acousticStage,
      sleepProbability: sleepProbability,
      breathingRegularity: breathingRegularity,
      snoreFraction: snoreFraction,
      sensors: sensors,
      context: context,
    );

    return SleepEstimate(
      sleepProbability: sleepProbability,
      fusedDepth: fusedDepth,
      fusedStage: fusedStage,
    );
  }

  SleepStage _stage({
    required double fusedDepth,
    required SleepStage acousticStage,
    required double sleepProbability,
    required double breathingRegularity,
    required double snoreFraction,
    required SleepSensorEpoch sensors,
    required SleepFusionContext context,
  }) {
    // Strong wake evidence from any modality overrides everything.
    final movingAwake = sensors.hasMotion && sensors.movement >= awakeMovement;
    final brightAwake =
        sensors.hasLight && (sensors.meanLux ?? 0) >= brightLux;
    final justUsedPhone = (context.minutesSincePhoneInteraction ?? 99) < 2.0;
    if (movingAwake || brightAwake || justUsedPhone || sleepProbability < 0.3) {
      return SleepStage.awake;
    }
    if (fusedDepth >= deepThreshold) {
      return SleepStage.deep;
    }
    // Mid depth: REM when breathing is irregular and snoring has dropped,
    // honouring the acoustic call.
    if (acousticStage == SleepStage.rem ||
        (breathingRegularity < remRegularityMax && snoreFraction < 0.15)) {
      return SleepStage.rem;
    }
    return SleepStage.light;
  }

  static double _sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));
}
