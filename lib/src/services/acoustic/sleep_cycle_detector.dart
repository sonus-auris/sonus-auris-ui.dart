import 'dart:math' as math;

import '../../models/acoustic_detection.dart';
import '../../models/sleep_stage.dart';
import 'sleep_periodicity.dart';
import 'spectral_features.dart';

/// Tunables for [SleepCycleDetector]. Defaults target a phone on a nightstand
/// within ~1 m of the sleeper.
class SleepConfig {
  const SleepConfig({
    this.epochSeconds = 30.0,
    this.depthSmoothingMinutes = 4.0,
    this.movementDeltaDb = 9.0,
    this.floorRiseDbPerSecond = 0.05,
    this.quietSpanDb = 14.0,
    this.deepThreshold = 0.62,
    this.shallowThreshold = 0.42,
    this.asleepThreshold = 0.35,
    this.awakeMovement = 0.45,
    this.remRegularityMax = 0.45,
    this.minCycleMinutes = 55.0,
    this.minBreathBpm = 6.0,
    this.maxBreathBpm = 30.0,
    this.periodicityEveryEpochs = 4,
    this.minPeriodMinutes = 60.0,
    this.maxPeriodMinutes = 130.0,
  });

  /// Length of one aggregated sleep epoch.
  final double epochSeconds;

  /// Time constant of the depth EMA (cycles are slow, so smooth hard).
  final double depthSmoothingMinutes;

  /// dB above the adaptive quiet floor that marks a frame as movement/arousal.
  final double movementDeltaDb;

  /// How fast the adaptive quiet floor drifts back up after a quiet stretch.
  final double floorRiseDbPerSecond;

  /// Loudness span (above the floor) over which depth fades from 1 to 0.
  final double quietSpanDb;

  /// Smoothed-depth level that counts as "descended into deep sleep".
  final double deepThreshold;

  /// Smoothed-depth level a descended sleeper must climb back above (shallow
  /// arousal) to close a cycle.
  final double shallowThreshold;

  /// Smoothed-depth level above which we consider the sleeper actually asleep
  /// (used to anchor sleep onset == start of cycle 1).
  final double asleepThreshold;

  /// Per-epoch movement fraction above which the epoch is classed [awake].
  final double awakeMovement;

  /// Breathing regularity below which a still, mid-depth epoch is classed [rem].
  final double remRegularityMax;

  /// A cycle shorter than this is treated as a micro-arousal, not a boundary.
  final double minCycleMinutes;

  final double minBreathBpm;
  final double maxBreathBpm;

  /// Re-run the FFT period estimate every N epochs (cheap, but no need each one).
  final int periodicityEveryEpochs;

  final double minPeriodMinutes;
  final double maxPeriodMinutes;
}

/// Stateful, pure sleep engine. Feed it [SpectralFrame]s (in capture order) plus
/// any snore detections emitted for the same frame; it aggregates ~30 s epochs,
/// estimates relative sleep depth and stage, finds the night's dominant cycle
/// length by FFT over the depth envelope, and emits:
///   * [AcousticDetectionKind.sleepEpoch] once per epoch (depth/stage/features), and
///   * [AcousticDetectionKind.sleepCycle] when a completed cycle boundary passes.
///
/// No I/O, no isolates — runs inside the existing analysis isolate and is
/// directly unit-testable.
class SleepCycleDetector {
  SleepCycleDetector({
    required this.frameSeconds,
    this.config = const SleepConfig(),
    this.captureSessionId = '',
  })  : _framesPerEpoch =
            math.max(1, (config.epochSeconds / frameSeconds).round()),
        _estimator = SleepPeriodicityEstimator(
          minPeriodMinutes: config.minPeriodMinutes,
          maxPeriodMinutes: config.maxPeriodMinutes,
        );

  /// Seconds of audio per analyzer frame (the hop).
  final double frameSeconds;
  final SleepConfig config;
  final String captureSessionId;

  final int _framesPerEpoch;
  final SleepPeriodicityEstimator _estimator;

  // --- Adaptive quiet floor (night-long) ---
  double? _floorDb;

  // --- Current-epoch accumulators ---
  int _epochFrames = 0;
  DateTime? _epochStart;
  double _dbSum = 0;
  int _movementFrames = 0;
  double _snoreSeconds = 0;
  final List<double> _lowBandSeries = []; // per-frame low-band power, this epoch

  // --- Cross-epoch state ---
  double _smoothedDepth = 0.0;
  bool _hasDepth = false;
  final List<double> _depthEnvelope = [];
  int _epochCount = 0;

  // --- Cycle boundary state machine ---
  DateTime? _onsetAt; // start of the current (in-progress) cycle
  bool _descended = false;
  double _cycleMinDepth = 1.0;
  double _cycleMaxDepth = 0.0;
  int _cycleIndex = 0;
  double _dominantCycleMinutes = 0;

  /// Coarse depth envelope (one value per epoch) — the FFT input and a chart
  /// source. Exposed for tests/diagnostics.
  List<double> get depthEnvelope => List.unmodifiable(_depthEnvelope);

  /// Latest FFT-estimated dominant cycle length (minutes); 0 until enough data.
  double get dominantCycleMinutes => _dominantCycleMinutes;

  /// Feed one analyzer frame plus the snore detections (if any) that the snore
  /// detector emitted for it. Returns any sleep detections produced.
  List<AcousticDetection> add(
    SpectralFrame frame,
    DateTime atUtc,
    List<AcousticDetection> snoreEvents,
  ) {
    _epochStart ??= atUtc;

    // Adaptive quiet floor: snaps down to new quiet, drifts slowly back up.
    final db = frame.db;
    if (_floorDb == null || db < _floorDb!) {
      _floorDb = db;
    } else {
      _floorDb = _floorDb! + config.floorRiseDbPerSecond * frameSeconds;
    }
    if (db > _floorDb! + config.movementDeltaDb) {
      _movementFrames += 1;
    }

    _dbSum += db;
    _lowBandSeries.add(frame.lowBandRatio * frame.totalPower);
    _epochFrames += 1;

    for (final e in snoreEvents) {
      if (e.kind == AcousticDetectionKind.snore) {
        _snoreSeconds += e.duration.inMilliseconds / 1000.0;
      }
    }

    if (_epochFrames >= _framesPerEpoch) {
      return _closeEpoch(atUtc);
    }
    return const [];
  }

  /// Flush the in-progress epoch (call when capture stops). Does not force a
  /// cycle boundary.
  List<AcousticDetection> flush() {
    if (_epochFrames == 0) {
      return const [];
    }
    return _closeEpoch(_epochStart!.add(
      Duration(milliseconds: (_epochFrames * frameSeconds * 1000).round()),
    ));
  }

  List<AcousticDetection> _closeEpoch(DateTime endAt) {
    final start = _epochStart ?? endAt;
    final out = <AcousticDetection>[];

    final meanDb = _epochFrames > 0 ? _dbSum / _epochFrames : config.quietSpanDb * -1;
    final movement =
        _epochFrames > 0 ? _movementFrames / _epochFrames : 0.0;
    final epochSeconds = endAt.difference(start).inMilliseconds / 1000.0;
    final snoreFraction =
        epochSeconds > 0 ? (_snoreSeconds / epochSeconds).clamp(0.0, 1.0) : 0.0;
    final breathing = _estimateBreathing();
    final floor = _floorDb ?? meanDb;

    // --- Depth: quieter + more regular + less movement == deeper ---
    final quietScore =
        (1 - (meanDb - floor) / config.quietSpanDb).clamp(0.0, 1.0);
    final movementScore = (1 - movement).clamp(0.0, 1.0);
    final regularityScore = breathing.regularity;
    // Steady snoring is a (weak) slow-wave cue, but only when breathing is regular.
    final snoreSteady =
        (snoreFraction * regularityScore).clamp(0.0, 1.0);
    final rawDepth = (0.40 * quietScore +
            0.30 * movementScore +
            0.22 * regularityScore +
            0.08 * snoreSteady)
        .clamp(0.0, 1.0);

    // EMA smoothing across epochs.
    final alpha =
        (config.epochSeconds / (config.depthSmoothingMinutes * 60.0))
            .clamp(0.05, 1.0);
    _smoothedDepth =
        _hasDepth ? _smoothedDepth + alpha * (rawDepth - _smoothedDepth) : rawDepth;
    _hasDepth = true;
    _depthEnvelope.add(_smoothedDepth);
    _epochCount += 1;

    final stage = _classifyStage(
      depth: _smoothedDepth,
      movement: movement,
      regularity: breathing.regularity,
      snoreFraction: snoreFraction,
    );

    out.add(AcousticDetection(
      kind: AcousticDetectionKind.sleepEpoch,
      startedAtUtc: start.toUtc(),
      endedAtUtc: endAt.toUtc(),
      confidence: 1.0,
      captureSessionId: captureSessionId,
      details: {
        'depth': double.parse(_smoothedDepth.toStringAsFixed(3)),
        'rawDepth': double.parse(rawDepth.toStringAsFixed(3)),
        'stage': stage.name,
        'meanDb': double.parse(meanDb.toStringAsFixed(1)),
        'movement': double.parse(movement.toStringAsFixed(3)),
        'snoreFraction': double.parse(snoreFraction.toStringAsFixed(3)),
        'breathingRateBpm': double.parse(breathing.bpm.toStringAsFixed(1)),
        'breathingRegularity':
            double.parse(breathing.regularity.toStringAsFixed(3)),
      },
    ));

    // --- Periodicity (FFT) refresh ---
    if (_epochCount % config.periodicityEveryEpochs == 0) {
      final est = _estimator.estimate(
        _depthEnvelope,
        config.epochSeconds / 60.0,
      );
      if (est.isValid) {
        _dominantCycleMinutes = est.periodMinutes;
      }
    }

    // --- Cycle boundary state machine ---
    final boundary = _updateCycle(_smoothedDepth, stage, endAt);
    if (boundary != null) {
      out.add(boundary);
    }

    // Reset epoch accumulators.
    _epochStart = endAt;
    _epochFrames = 0;
    _dbSum = 0;
    _movementFrames = 0;
    _snoreSeconds = 0;
    _lowBandSeries.clear();
    return out;
  }

  SleepStage _classifyStage({
    required double depth,
    required double movement,
    required double regularity,
    required double snoreFraction,
  }) {
    if (movement >= config.awakeMovement) {
      return SleepStage.awake;
    }
    if (depth < config.asleepThreshold) {
      // Shallow + still: ambiguous between drowsy-awake and light; if breathing
      // is irregular and there's some movement, call awake, else light.
      return movement > config.awakeMovement * 0.5
          ? SleepStage.awake
          : SleepStage.light;
    }
    if (depth >= config.deepThreshold) {
      return SleepStage.deep;
    }
    // Mid depth: REM if breathing is irregular and snoring has dropped off.
    if (regularity < config.remRegularityMax && snoreFraction < 0.15) {
      return SleepStage.rem;
    }
    return SleepStage.light;
  }

  AcousticDetection? _updateCycle(
    double depth,
    SleepStage stage,
    DateTime atUtc,
  ) {
    // Anchor sleep onset (= start of cycle 1) at the first asleep epoch.
    if (_onsetAt == null) {
      if (depth >= config.asleepThreshold) {
        _onsetAt = atUtc;
        _cycleMinDepth = depth;
        _cycleMaxDepth = depth;
      }
      return null;
    }

    _cycleMinDepth = math.min(_cycleMinDepth, depth);
    _cycleMaxDepth = math.max(_cycleMaxDepth, depth);
    if (depth >= config.deepThreshold) {
      _descended = true;
    }

    final cycleMinutes =
        atUtc.difference(_onsetAt!).inMilliseconds / 60000.0;
    final reachedShallow =
        depth <= config.shallowThreshold || stage == SleepStage.awake;
    if (_descended &&
        reachedShallow &&
        cycleMinutes >= config.minCycleMinutes) {
      // Close the cycle at this arousal.
      _cycleIndex += 1;
      final detection = AcousticDetection(
        kind: AcousticDetectionKind.sleepCycle,
        startedAtUtc: _onsetAt!.toUtc(),
        endedAtUtc: atUtc.toUtc(),
        confidence: (_cycleMaxDepth - _cycleMinDepth).clamp(0.2, 1.0),
        captureSessionId: captureSessionId,
        details: {
          'cycleIndex': _cycleIndex,
          'lengthMinutes': double.parse(cycleMinutes.toStringAsFixed(1)),
          'minDepth': double.parse(_cycleMinDepth.toStringAsFixed(3)),
          'maxDepth': double.parse(_cycleMaxDepth.toStringAsFixed(3)),
          'dominantCycleMinutes':
              double.parse(_dominantCycleMinutes.toStringAsFixed(1)),
          'stage': stage.name,
        },
      );
      // Start the next cycle from this boundary.
      _onsetAt = atUtc;
      _descended = false;
      _cycleMinDepth = depth;
      _cycleMaxDepth = depth;
      return detection;
    }
    return null;
  }

  /// Estimates breathing rate + regularity from this epoch's per-frame low-band
  /// power series via autocorrelation. The low-band envelope rises and falls once
  /// per breath; the strongest autocorrelation lag in the human breathing band is
  /// the period, and its (normalized) height is the regularity.
  ({double bpm, double regularity}) _estimateBreathing() {
    final n = _lowBandSeries.length;
    if (n < 8 || frameSeconds <= 0) {
      return (bpm: 0.0, regularity: 0.0);
    }
    // Mean-remove.
    var mean = 0.0;
    for (final v in _lowBandSeries) {
      mean += v;
    }
    mean /= n;
    final x = List<double>.generate(n, (i) => _lowBandSeries[i] - mean);
    var zero = 0.0;
    for (final v in x) {
      zero += v * v;
    }
    if (zero <= 1e-12) {
      return (bpm: 0.0, regularity: 0.0);
    }

    final minLag = math.max(1, (60.0 / config.maxBreathBpm / frameSeconds).round());
    final maxLag = math.min(
      n - 1,
      (60.0 / config.minBreathBpm / frameSeconds).round(),
    );
    if (maxLag <= minLag) {
      return (bpm: 0.0, regularity: 0.0);
    }

    var bestLag = -1;
    var bestCorr = 0.0;
    for (var lag = minLag; lag <= maxLag; lag++) {
      var acc = 0.0;
      for (var i = lag; i < n; i++) {
        acc += x[i] * x[i - lag];
      }
      final norm = acc / zero;
      if (norm > bestCorr) {
        bestCorr = norm;
        bestLag = lag;
      }
    }
    if (bestLag <= 0 || bestCorr <= 0) {
      return (bpm: 0.0, regularity: 0.0);
    }
    final periodSeconds = bestLag * frameSeconds;
    final bpm = (60.0 / periodSeconds)
        .clamp(config.minBreathBpm, config.maxBreathBpm);
    return (bpm: bpm, regularity: bestCorr.clamp(0.0, 1.0));
  }
}
