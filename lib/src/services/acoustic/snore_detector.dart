// Heuristic FFT snore detector: flags low, tonal, rhythmic bursts as snore episodes and watches for apnea-like gaps.
import 'dart:math' as math;

import '../../models/acoustic_detection.dart';
import 'spectral_features.dart';

/// Tunables for [SnoreDetector]. Defaults target a phone on a nightstand.
class SnoreConfig {
  const SnoreConfig({
    this.loudDb = -38.0,
    this.lowBandRatioMin = 0.32,
    this.centroidMaxHz = 900.0,
    this.flatnessMax = 0.55,
    this.minEpisodeSeconds = 0.25,
    this.maxEpisodeSeconds = 4.0,
    this.snoreLikeFraction = 0.6,
    this.offHangSeconds = 0.2,
    this.apneaGapSeconds = 10.0,
    this.apneaMinPriorSnores = 3,
    this.apneaIntervalMultiple = 2.0,
  });

  /// A frame counts as part of a (loud) burst at or above this dBFS level.
  final double loudDb;

  /// Snore-shaped frames put at least this fraction of power in 60–300 Hz...
  final double lowBandRatioMin;

  /// ...with a low spectral centroid...
  final double centroidMaxHz;

  /// ...and tonal (not hiss-like) content.
  final double flatnessMax;

  final double minEpisodeSeconds;
  final double maxEpisodeSeconds;

  /// Fraction of an episode's frames that must be snore-shaped to call it a snore.
  final double snoreLikeFraction;

  /// A burst only ends after this much continuous non-loud audio (debounce).
  final double offHangSeconds;

  /// Silence longer than this between regular snores looks like a breathing
  /// cessation (an apnea-like gap).
  final double apneaGapSeconds;

  /// Need at least this many regular snores before a gap counts as apnea-like.
  final int apneaMinPriorSnores;

  /// ...and the gap must also exceed this multiple of the recent median interval.
  final double apneaIntervalMultiple;
}

/// Stateful, pure detector: feed it [SpectralFrame]s in capture order and it
/// emits [AcousticDetectionKind.snore] episodes plus [apneaPattern] events when
/// regular snoring is interrupted by a long cessation then resumes.
class SnoreDetector {
  SnoreDetector({
    required this.frameSeconds,
    this.config = const SnoreConfig(),
    this.captureSessionId = '',
  });

  /// Seconds of audio represented by one frame (the analyzer hop).
  final double frameSeconds;
  final SnoreConfig config;
  final String captureSessionId;

  bool _inEpisode = false;
  DateTime? _episodeStart;
  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _episodeFrames = 0;
  int _snoreLikeFrames = 0;
  double _offSeconds = 0;
  double _episodePeakDb = -999;

  DateTime? _lastSnoreEnd;
  final List<double> _recentIntervals = [];
  int _consecutiveSnores = 0;

  List<AcousticDetection> add(SpectralFrame frame, DateTime atUtc) {
    _lastFrameAt = atUtc;
    final out = <AcousticDetection>[];
    final loud = frame.db >= config.loudDb;
    final snoreLike = frame.lowBandRatio >= config.lowBandRatioMin &&
        frame.centroidHz <= config.centroidMaxHz &&
        frame.flatness <= config.flatnessMax;

    if (loud) {
      if (!_inEpisode) {
        // Episode onset. First check whether the silence we just left was an
        // apnea-like cessation following a run of regular snores.
        final apnea = _maybeApnea(atUtc);
        if (apnea != null) {
          out.add(apnea);
        }
        _inEpisode = true;
        _episodeStart = atUtc;
        _episodeFrames = 0;
        _snoreLikeFrames = 0;
        _episodePeakDb = -999;
      }
      _offSeconds = 0;
      _episodeFrames += 1;
      if (snoreLike) {
        _snoreLikeFrames += 1;
      }
      _episodePeakDb = math.max(_episodePeakDb, frame.db);
    } else if (_inEpisode) {
      _offSeconds += frameSeconds;
      if (_offSeconds >= config.offHangSeconds) {
        final snore = _closeEpisode(atUtc);
        if (snore != null) {
          out.add(snore);
        }
      }
    }
    return out;
  }

  /// Flushes any open episode (call when the analysis gate closes / capture stops).
  List<AcousticDetection> flush() {
    if (!_inEpisode) {
      return const [];
    }
    final snore = _closeEpisode(_lastFrameAt);
    return snore == null ? const [] : [snore];
  }

  AcousticDetection? _closeEpisode(DateTime endAt) {
    final start = _episodeStart;
    _inEpisode = false;
    _offSeconds = 0;
    if (start == null || _episodeFrames == 0) {
      return null;
    }
    // The burst ended [offHangSeconds] ago; trim the trailing silence.
    final end = endAt.subtract(
      Duration(milliseconds: (config.offHangSeconds * 1000).round()),
    );
    final durationSeconds = end.difference(start).inMilliseconds / 1000.0;
    final fraction = _snoreLikeFrames / _episodeFrames;
    if (durationSeconds < config.minEpisodeSeconds ||
        durationSeconds > config.maxEpisodeSeconds ||
        fraction < config.snoreLikeFraction) {
      return null;
    }
    // Track timeline for apnea detection.
    final lastEnd = _lastSnoreEnd;
    if (lastEnd != null) {
      final interval = end.difference(lastEnd).inMilliseconds / 1000.0;
      if (interval > 0 && interval <= config.apneaGapSeconds) {
        _recentIntervals.add(interval);
        if (_recentIntervals.length > 10) {
          _recentIntervals.removeAt(0);
        }
        _consecutiveSnores += 1;
      } else {
        // Gap was irregular/long; the run of regular snores is broken.
        _consecutiveSnores = 1;
        _recentIntervals.clear();
      }
    } else {
      _consecutiveSnores = 1;
    }
    _lastSnoreEnd = end;

    final confidence = (fraction).clamp(0.0, 1.0);
    return AcousticDetection(
      kind: AcousticDetectionKind.snore,
      startedAtUtc: start.toUtc(),
      endedAtUtc: end.toUtc(),
      confidence: confidence,
      captureSessionId: captureSessionId,
      details: {
        'peakDb': double.parse(_episodePeakDb.toStringAsFixed(1)),
        'durationSeconds': double.parse(durationSeconds.toStringAsFixed(2)),
      },
    );
  }

  AcousticDetection? _maybeApnea(DateTime resumeAt) {
    final lastEnd = _lastSnoreEnd;
    if (lastEnd == null ||
        _consecutiveSnores < config.apneaMinPriorSnores ||
        _recentIntervals.isEmpty) {
      return null;
    }
    final gap = resumeAt.difference(lastEnd).inMilliseconds / 1000.0;
    if (gap < config.apneaGapSeconds) {
      return null;
    }
    final median = _median(_recentIntervals);
    if (gap < config.apneaIntervalMultiple * median) {
      return null;
    }
    // A regular snoring run was interrupted by a long cessation, then resumed.
    final detection = AcousticDetection(
      kind: AcousticDetectionKind.apneaPattern,
      startedAtUtc: lastEnd.toUtc(),
      endedAtUtc: resumeAt.toUtc(),
      confidence: (gap / (config.apneaGapSeconds * 3)).clamp(0.3, 1.0),
      captureSessionId: captureSessionId,
      details: {
        'gapSeconds': double.parse(gap.toStringAsFixed(1)),
        'priorSnores': _consecutiveSnores,
        'medianIntervalSeconds': double.parse(median.toStringAsFixed(1)),
        'note': 'Non-diagnostic acoustic pattern, not a medical diagnosis.',
      },
    );
    // Reset the run; the resumption starts a fresh sequence.
    _consecutiveSnores = 0;
    _recentIntervals.clear();
    return detection;
  }

  static double _median(List<double> values) {
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) {
      return sorted[mid];
    }
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }
}
