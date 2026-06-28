import 'dart:math' as math;

import '../../models/acoustic_detection.dart';
import '../sleep_signal_model.dart';
import 'spectral_features.dart';

/// Tunables for [SleepCycleDetector].
///
/// The detector is intentionally heuristic and non-diagnostic: it uses FFT
/// shape, snore-like bursts, quiet breathing-like frames, and restless arousal
/// cues to estimate a personal cycle length. It never infers medical sleep
/// disorders.
class SleepCycleConfig {
  const SleepCycleConfig({
    this.initialCycleMinutes = 90.0,
    this.cycleMinutesByIndex = const [],
    this.alarmsEnabled = true,
    this.alarmCycles = const {5, 6},
    this.minCycleMinutes = 75.0,
    this.maxCycleMinutes = 120.0,
    this.sleepOnsetMinutes = 10.0,
    this.fallbackGraceMinutes = 8.0,
    this.bucketSeconds = 60.0,
    this.deepSleepDepthScore = 0.62,
    this.deepSleepBucketFraction = 0.55,
    this.maxGapMinutes = 5.0,
    this.motionSignalEnabled = false,
    this.ambientLightSignalEnabled = false,
    this.phoneContextSignalEnabled = false,
  });

  final double initialCycleMinutes;
  final List<double> cycleMinutesByIndex;
  final bool alarmsEnabled;
  final Set<int> alarmCycles;
  final double minCycleMinutes;
  final double maxCycleMinutes;
  final double sleepOnsetMinutes;
  final double fallbackGraceMinutes;
  final double bucketSeconds;
  final double deepSleepDepthScore;
  final double deepSleepBucketFraction;

  /// A jump in frame timestamps larger than this (a capture interruption: a
  /// phone call pausing the audio session, the analyzer falling far behind, or a
  /// wall-clock change) resets the in-progress sleep estimate so we re-detect
  /// onset cleanly instead of treating the gap as continuous sleep and firing a
  /// phantom cycle/alarm.
  final double maxGapMinutes;

  final bool motionSignalEnabled;
  final bool ambientLightSignalEnabled;
  final bool phoneContextSignalEnabled;

  SleepCycleConfig normalized() {
    final minCycle = minCycleMinutes.clamp(75.0, 120.0).toDouble();
    final maxCycle = math
        .max(maxCycleMinutes.clamp(75.0, 120.0).toDouble(), minCycle)
        .toDouble();
    final normalizedCycles = cycleMinutesByIndex
        .map((minutes) => minutes.clamp(minCycle, maxCycle).toDouble())
        .where((minutes) => minutes.isFinite)
        .take(12)
        .toList(growable: false);
    return SleepCycleConfig(
      initialCycleMinutes: initialCycleMinutes.clamp(minCycle, maxCycle),
      cycleMinutesByIndex: normalizedCycles,
      alarmsEnabled: alarmsEnabled,
      alarmCycles: alarmCycles.where((cycle) => cycle > 0).toSet(),
      minCycleMinutes: minCycle,
      maxCycleMinutes: maxCycle,
      sleepOnsetMinutes: sleepOnsetMinutes.clamp(1.0, 45.0),
      fallbackGraceMinutes: fallbackGraceMinutes.clamp(0.0, 30.0),
      bucketSeconds: bucketSeconds.clamp(10.0, 300.0),
      deepSleepDepthScore: deepSleepDepthScore.clamp(0.0, 1.0).toDouble(),
      deepSleepBucketFraction: deepSleepBucketFraction
          .clamp(0.0, 1.0)
          .toDouble(),
      maxGapMinutes: maxGapMinutes.clamp(1.0, 60.0).toDouble(),
      motionSignalEnabled: motionSignalEnabled,
      ambientLightSignalEnabled: ambientLightSignalEnabled,
      phoneContextSignalEnabled: phoneContextSignalEnabled,
    );
  }
}

/// Estimates sleep onset, cycle boundaries, and wake-window alarms from
/// FFT-derived acoustic frames.
class SleepCycleDetector {
  SleepCycleDetector({
    required this.frameSeconds,
    SleepCycleConfig config = const SleepCycleConfig(),
    this.captureSessionId = '',
  }) : config = config.normalized(),
       _cycleMinutesByIndex = config.normalized().cycleMinutesByIndex.toList();

  final double frameSeconds;
  final SleepCycleConfig config;
  final String captureSessionId;

  DateTime? _bucketStartedAt;
  DateTime? _lastFrameAtUtc;
  _Bucket _bucket = _Bucket();
  DateTime? _sleepStartedAt;
  DateTime? _lastCycleBoundaryAt;
  final List<double> _cycleMinutesByIndex;
  int _nextCycleIndex = 1;
  int _learnedObservations = 0;
  int _cycleBuckets = 0;
  int _deepCycleBuckets = 0;
  final Set<int> _deepCycleIndexes = {};
  final List<_BucketSummary> _recent = [];
  static const SleepProbabilityModel _probabilityModel =
      SleepProbabilityModel();

  Duration get _bucketDuration =>
      Duration(milliseconds: (config.bucketSeconds * 1000).round());

  List<AcousticDetection> add(SpectralFrame frame, DateTime atUtc) {
    final utc = atUtc.toUtc();
    // A large jump in frame time means capture was interrupted (or the clock
    // moved): drop the in-progress estimate and re-detect sleep onset rather
    // than counting the gap as elapsed sleep and emitting a phantom cycle.
    final last = _lastFrameAtUtc;
    if (last != null &&
        utc.difference(last).inMilliseconds.abs() / 60000.0 >
            config.maxGapMinutes) {
      _resetSleepSession();
    }
    _lastFrameAtUtc = utc;
    final bucketStart = _bucketStartFor(utc);
    final out = <AcousticDetection>[];
    _bucketStartedAt ??= bucketStart;
    while (_bucketStartedAt!.isBefore(bucketStart)) {
      out.addAll(_closeBucket(_bucketStartedAt!));
      _bucketStartedAt = _bucketStartedAt!.add(_bucketDuration);
      _bucket = _Bucket();
    }
    _bucket.add(frame);
    return out;
  }

  List<AcousticDetection> flush() {
    final startedAt = _bucketStartedAt;
    if (startedAt == null || _bucket.frames == 0) {
      return const [];
    }
    final out = _closeBucket(startedAt);
    _bucketStartedAt = null;
    _bucket = _Bucket();
    return out;
  }

  /// Drops in-progress sleep-session state (onset, cycle progress, recent
  /// buckets, per-cycle depth) after a capture gap. Learned per-cycle minute
  /// seeds are kept — they are a valid prior for the resumed sleep.
  void _resetSleepSession() {
    _bucketStartedAt = null;
    _bucket = _Bucket();
    _sleepStartedAt = null;
    _lastCycleBoundaryAt = null;
    _nextCycleIndex = 1;
    _recent.clear();
    _deepCycleIndexes.clear();
    _resetCycleDepth();
  }

  DateTime _bucketStartFor(DateTime atUtc) {
    final micros = atUtc.microsecondsSinceEpoch;
    final bucketMicros = _bucketDuration.inMicroseconds;
    return DateTime.fromMicrosecondsSinceEpoch(
      micros - micros.remainder(bucketMicros),
      isUtc: true,
    );
  }

  List<AcousticDetection> _closeBucket(DateTime startedAt) {
    final summary = _bucket.summary(
      startedAt: startedAt,
      endedAt: startedAt.add(_bucketDuration),
    );
    if (summary.frames == 0) {
      return const [];
    }
    _recent.add(summary);
    final maxRecent = math.max(4, (30 * 60 / config.bucketSeconds).ceil());
    if (_recent.length > maxRecent) {
      _recent.removeAt(0);
    }

    if (_sleepStartedAt == null) {
      return _maybeStartSleep();
    }
    final boundary = _maybeCycleBoundary(summary);
    return boundary == null ? const [] : [boundary];
  }

  List<AcousticDetection> _maybeStartSleep() {
    final needed = math.max(
      2,
      (config.sleepOnsetMinutes * 60 / config.bucketSeconds).ceil(),
    );
    if (_recent.length < needed) {
      return const [];
    }
    final window = _recent.sublist(_recent.length - needed);
    final sleepBuckets = window.where((b) => b.sleepScore >= 0.48).length;
    final averageWake =
        window.fold<double>(0, (sum, b) => sum + b.wakeScore) / window.length;
    if (sleepBuckets < math.max(2, (needed * 0.72).ceil()) ||
        averageWake > 0.36) {
      return const [];
    }

    _sleepStartedAt = window.first.startedAt;
    _lastCycleBoundaryAt = _sleepStartedAt;
    _nextCycleIndex = 1;
    _resetCycleDepth();
    final probability = _probabilityFor(window.last);
    return [
      AcousticDetection(
        kind: AcousticDetectionKind.sleepCycle,
        startedAtUtc: window.first.startedAt,
        endedAtUtc: window.last.endedAt,
        confidence: _confidenceFor(window.last, observedCycleMinutes: null),
        captureSessionId: captureSessionId,
        details: {
          'cycleIndex': 0,
          'stageHint': 'sleep onset',
          'estimatedCycleMinutes': _round1(_cycleMinutesFor(1)),
          'cycleMinutesByIndex': _roundedCycleMinutes(),
          'sleepScore': _round2(window.last.sleepScore),
          'sleepProbability': _round2(probability.sleepProbability),
          'probabilitySignals': probability.activeSignals,
          'note': 'Non-diagnostic acoustic sleep estimate.',
        },
      ),
    ];
  }

  AcousticDetection? _maybeCycleBoundary(_BucketSummary summary) {
    final lastBoundary = _lastCycleBoundaryAt;
    if (lastBoundary == null) {
      return null;
    }
    _trackCycleDepth(summary);
    final elapsedMinutes =
        summary.endedAt.difference(lastBoundary).inSeconds / 60.0;
    final expectedMinutes = _cycleMinutesFor(_nextCycleIndex);
    final bucketMinutes = config.bucketSeconds / 60.0;
    final arousalBoundary =
        summary.arousalScore >= 0.55 &&
        elapsedMinutes >= config.minCycleMinutes &&
        elapsedMinutes <= config.maxCycleMinutes + bucketMinutes;
    final fallbackTarget = _hasPersonalCycleSeed(_nextCycleIndex)
        ? expectedMinutes + config.fallbackGraceMinutes
        : config.maxCycleMinutes + bucketMinutes;
    final fallbackBoundary = elapsedMinutes >= fallbackTarget;
    if (!arousalBoundary && !fallbackBoundary) {
      return null;
    }

    final observedMinutes = arousalBoundary ? elapsedMinutes : null;
    if (observedMinutes != null) {
      _learnFromObservedCycle(_nextCycleIndex, observedMinutes);
    }
    final cycleIndex = _nextCycleIndex;
    _nextCycleIndex += 1;
    _lastCycleBoundaryAt = summary.endedAt;
    final deepSleepCycle = _currentCycleWasDeep;
    if (deepSleepCycle) {
      _deepCycleIndexes.add(cycleIndex);
    }
    final deferFifthAlarm =
        cycleIndex == 5 && (_deepCycleIndexes.contains(4) || deepSleepCycle);
    final alarmCycle =
        config.alarmsEnabled &&
        config.alarmCycles.contains(cycleIndex) &&
        !deferFifthAlarm;
    final kind = alarmCycle
        ? AcousticDetectionKind.sleepCycleAlarm
        : AcousticDetectionKind.sleepCycle;
    final probability = _probabilityFor(summary);
    _resetCycleDepth();
    return AcousticDetection(
      kind: kind,
      startedAtUtc: summary.startedAt,
      endedAtUtc: summary.endedAt,
      confidence: _confidenceFor(
        summary,
        observedCycleMinutes: observedMinutes,
      ),
      captureSessionId: captureSessionId,
      details: {
        'cycleIndex': cycleIndex,
        'alarmCycle': alarmCycle,
        'deepSleepCycle': deepSleepCycle,
        if (deferFifthAlarm) 'alarmDeferred': true,
        if (deferFifthAlarm) 'deferredToCycle': 6,
        'estimatedCycleMinutes': _round1(_cycleMinutesFor(cycleIndex)),
        'expectedCycleMinutes': _round1(expectedMinutes),
        if (observedMinutes != null)
          'observedCycleMinutes': _round1(observedMinutes),
        'cycleMinutesByIndex': _roundedCycleMinutes(),
        'elapsedSleepMinutes': _round1(
          summary.endedAt.difference(_sleepStartedAt!).inSeconds / 60.0,
        ),
        'learnedFromUser': _learnedObservations > 0,
        'stageHint': _stageHint(summary),
        'sleepScore': _round2(summary.sleepScore),
        'arousalScore': _round2(summary.arousalScore),
        'sleepProbability': _round2(probability.sleepProbability),
        'probabilitySignals': probability.activeSignals,
        'snoreFraction': _round2(summary.snoreFraction),
        'breathingFraction': _round2(summary.breathingFraction),
        'note': 'Non-diagnostic acoustic sleep estimate.',
      },
    );
  }

  void _learnFromObservedCycle(int cycleIndex, double observedMinutes) {
    final bounded = observedMinutes.clamp(
      config.minCycleMinutes,
      config.maxCycleMinutes,
    );
    final weight = _learnedObservations == 0 ? 0.35 : 0.22;
    final current = _cycleMinutesFor(cycleIndex);
    final learned = ((1 - weight) * current + weight * bounded).clamp(
      config.minCycleMinutes,
      config.maxCycleMinutes,
    );
    while (_cycleMinutesByIndex.length < cycleIndex) {
      _cycleMinutesByIndex.add(config.initialCycleMinutes);
    }
    _cycleMinutesByIndex[cycleIndex - 1] = learned.toDouble();
    _learnedObservations += 1;
  }

  void _trackCycleDepth(_BucketSummary summary) {
    if (summary.arousalScore >= 0.55) {
      return;
    }
    _cycleBuckets += 1;
    if (summary.depthScore >= config.deepSleepDepthScore &&
        summary.sleepScore >= 0.62) {
      _deepCycleBuckets += 1;
    }
  }

  bool get _currentCycleWasDeep {
    if (_cycleBuckets == 0) {
      return false;
    }
    return _deepCycleBuckets / _cycleBuckets >= config.deepSleepBucketFraction;
  }

  void _resetCycleDepth() {
    _cycleBuckets = 0;
    _deepCycleBuckets = 0;
  }

  SleepProbabilityEstimate _probabilityFor(_BucketSummary summary) {
    return _probabilityModel.estimate(
      sample: SleepSignalSample(
        acousticSleepScore: summary.sleepScore,
        acousticArousalScore: summary.arousalScore,
      ),
      consent: SleepSignalConsent(
        audio: true,
        motion: config.motionSignalEnabled,
        ambientLight: config.ambientLightSignalEnabled,
        phoneContext: config.phoneContextSignalEnabled,
      ),
    );
  }

  double _cycleMinutesFor(int cycleIndex) {
    if (cycleIndex > 0 && cycleIndex <= _cycleMinutesByIndex.length) {
      return _cycleMinutesByIndex[cycleIndex - 1];
    }
    if (_cycleMinutesByIndex.isNotEmpty) {
      return _cycleMinutesByIndex.last;
    }
    return config.initialCycleMinutes;
  }

  bool _hasPersonalCycleSeed(int cycleIndex) {
    if (cycleIndex <= 0 || cycleIndex > _cycleMinutesByIndex.length) {
      return false;
    }
    return (_cycleMinutesByIndex[cycleIndex - 1] - 90.0).abs() > 0.1;
  }

  List<double> _roundedCycleMinutes() {
    final count = math.max(_cycleMinutesByIndex.length, 6);
    return List<double>.generate(
      count,
      (index) => _round1(_cycleMinutesFor(index + 1)),
      growable: false,
    );
  }

  double _confidenceFor(
    _BucketSummary summary, {
    required double? observedCycleMinutes,
  }) {
    final evidence =
        0.38 * summary.sleepScore +
        0.32 * summary.arousalScore +
        0.20 * summary.snoreFraction +
        (observedCycleMinutes == null ? 0.08 : 0.18);
    return evidence.clamp(0.35, 0.96);
  }

  String _stageHint(_BucketSummary summary) {
    final lastBoundary = _lastCycleBoundaryAt;
    if (lastBoundary == null) {
      return 'sleep';
    }
    final elapsed = summary.endedAt.difference(lastBoundary).inSeconds / 60.0;
    final phase = (elapsed / _cycleMinutesFor(_nextCycleIndex)).clamp(0.0, 1.5);
    if (summary.arousalScore >= 0.55) {
      return 'light sleep / wake window';
    }
    if (phase < 0.20) {
      return 'settling';
    }
    if (phase > 0.76) {
      return 'light sleep / REM window';
    }
    if (summary.depthScore >= 0.55) {
      return 'deep sleep leaning';
    }
    return 'stable sleep';
  }

  static double _round1(double value) => double.parse(value.toStringAsFixed(1));

  static double _round2(double value) => double.parse(value.toStringAsFixed(2));
}

class _Bucket {
  int frames = 0;
  int breathingFrames = 0;
  int snoreFrames = 0;
  int wakeFrames = 0;
  double dbSum = 0;
  double lowBandSum = 0;

  void add(SpectralFrame frame) {
    frames += 1;
    dbSum += frame.db;
    lowBandSum += frame.lowBandRatio;

    final audible = frame.db >= -68.0;
    final snoreLike =
        frame.db >= -48.0 &&
        frame.lowBandRatio >= 0.24 &&
        frame.centroidHz <= 1000.0 &&
        frame.flatness <= 0.70;
    final breathingLike =
        audible &&
        frame.db <= -24.0 &&
        frame.centroidHz <= 1600.0 &&
        frame.rolloffHz <= 3600.0 &&
        frame.speechBandRatio <= 0.55 &&
        frame.flatness <= 0.88;
    final wakeLike =
        frame.db >= -35.0 &&
        (frame.speechBandRatio >= 0.45 ||
            frame.centroidHz >= 1800.0 ||
            frame.rolloffHz >= 3800.0);

    if (breathingLike || snoreLike) {
      breathingFrames += 1;
    }
    if (snoreLike) {
      snoreFrames += 1;
    }
    if (wakeLike) {
      wakeFrames += 1;
    }
  }

  _BucketSummary summary({
    required DateTime startedAt,
    required DateTime endedAt,
  }) {
    if (frames == 0) {
      return _BucketSummary.empty(startedAt: startedAt, endedAt: endedAt);
    }
    final breathing = breathingFrames / frames;
    final snore = snoreFrames / frames;
    final wake = wakeFrames / frames;
    final lowBand = lowBandSum / frames;
    final averageDb = dbSum / frames;
    final sleepScore = (0.65 * breathing + 0.35 * snore - 0.55 * wake).clamp(
      0.0,
      1.0,
    );
    final arousalScore =
        (0.70 * wake +
                0.20 * (1 - breathing) +
                (averageDb >= -34.0 ? 0.10 : 0.0))
            .clamp(0.0, 1.0);
    final depthScore =
        (0.40 * breathing + 0.35 * lowBand + 0.25 * snore - 0.45 * wake).clamp(
          0.0,
          1.0,
        );
    return _BucketSummary(
      startedAt: startedAt,
      endedAt: endedAt,
      frames: frames,
      sleepScore: sleepScore,
      arousalScore: arousalScore,
      wakeScore: wake,
      depthScore: depthScore,
      breathingFraction: breathing,
      snoreFraction: snore,
    );
  }
}

class _BucketSummary {
  const _BucketSummary({
    required this.startedAt,
    required this.endedAt,
    required this.frames,
    required this.sleepScore,
    required this.arousalScore,
    required this.wakeScore,
    required this.depthScore,
    required this.breathingFraction,
    required this.snoreFraction,
  });

  factory _BucketSummary.empty({
    required DateTime startedAt,
    required DateTime endedAt,
  }) {
    return _BucketSummary(
      startedAt: startedAt,
      endedAt: endedAt,
      frames: 0,
      sleepScore: 0,
      arousalScore: 0,
      wakeScore: 0,
      depthScore: 0,
      breathingFraction: 0,
      snoreFraction: 0,
    );
  }

  final DateTime startedAt;
  final DateTime endedAt;
  final int frames;
  final double sleepScore;
  final double arousalScore;
  final double wakeScore;
  final double depthScore;
  final double breathingFraction;
  final double snoreFraction;
}
