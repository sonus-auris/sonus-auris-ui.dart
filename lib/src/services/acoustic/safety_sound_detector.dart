// Conservative on-device detector for sudden loud noises and repeated raised-voice patterns.
import 'dart:math' as math;

import '../../models/acoustic_detection.dart';
import 'spectral_features.dart';

/// Tunables for [SafetySoundDetector]. The defaults favor precision over recall:
/// missing an ambiguous event is preferable to labeling ordinary conversation
/// or music as an altercation.
class SafetySoundConfig {
  const SafetySoundConfig({
    this.impulseDb = -10,
    this.impulsePeak = 0.94,
    this.impulseRiseDb = 10,
    this.impulseCrestFactor = 2.8,
    this.impulseHighBandRatio = 0.22,
    this.impulseFlatness = 0.45,
    this.impulseClippingFraction = 0.005,
    this.impulseCooldownSeconds = 2,
    this.raisedVoiceDb = -24,
    this.raisedVoiceSpeechBandRatio = 0.45,
    this.raisedVoiceMinSeconds = 0.55,
    this.raisedVoiceGapSeconds = 0.28,
    this.argumentWindowSeconds = 10,
    this.argumentMinBursts = 3,
    this.argumentCooldownSeconds = 20,
  });

  final double impulseDb;
  final double impulsePeak;
  final double impulseRiseDb;
  final double impulseCrestFactor;
  final double impulseHighBandRatio;
  final double impulseFlatness;
  final double impulseClippingFraction;
  final double impulseCooldownSeconds;

  final double raisedVoiceDb;
  final double raisedVoiceSpeechBandRatio;
  final double raisedVoiceMinSeconds;
  final double raisedVoiceGapSeconds;

  final double argumentWindowSeconds;
  final int argumentMinBursts;
  final double argumentCooldownSeconds;
}

/// Detects acoustic evidence that may be useful for safety review without
/// transcribing audio or inferring who is present.
///
/// A sudden-loud-noise event requires a rapid level rise plus transient or
/// broadband evidence. A raised-voice event requires sustained, loud,
/// speech-band energy. A possible-argument-pattern event requires multiple
/// distinct raised-voice bursts separated by quieter gaps. That last label is
/// deliberately a pattern, not a claim: a single speaker, television, music,
/// or environmental noise can produce similar acoustics.
class SafetySoundDetector {
  SafetySoundDetector({
    required this.frameSeconds,
    this.config = const SafetySoundConfig(),
    this.captureSessionId = '',
  }) : assert(frameSeconds > 0);

  final double frameSeconds;
  final SafetySoundConfig config;
  final String captureSessionId;

  double? _ambientDb;
  DateTime? _impulseSuppressUntil;
  DateTime? _argumentSuppressUntil;
  DateTime? _lastFrameAt;

  DateTime? _episodeStart;
  DateTime? _lastRaisedAt;
  int _candidateFrames = 0;
  int _quietFrames = 0;
  double _dbSum = 0;
  double _speechBandSum = 0;
  double _maxDb = -120;
  bool _raisedEmitted = false;

  final List<_RaisedVoiceBurst> _recentBursts = [];

  List<AcousticDetection> add(SpectralFrame frame, DateTime atUtc) {
    final utc = atUtc.toUtc();
    _lastFrameAt = utc;
    final out = <AcousticDetection>[];
    final impulse = _detectImpulse(frame, utc);
    if (impulse != null) {
      out.add(impulse);
    }
    out.addAll(_trackRaisedVoice(frame, utc));
    return out;
  }

  List<AcousticDetection> flush() {
    final endedAt = _lastRaisedAt ?? _lastFrameAt;
    if (_episodeStart == null || endedAt == null) {
      _clearEpisode();
      return const [];
    }
    return _finishEpisode(endedAt);
  }

  void reset() {
    _ambientDb = null;
    _impulseSuppressUntil = null;
    _argumentSuppressUntil = null;
    _lastFrameAt = null;
    _recentBursts.clear();
    _clearEpisode();
  }

  AcousticDetection? _detectImpulse(SpectralFrame frame, DateTime atUtc) {
    final baseline = _ambientDb ?? -80.0;
    final riseDb = frame.db - baseline;
    final loud =
        frame.db >= config.impulseDb ||
        frame.peakAmplitude >= config.impulsePeak;
    final transient =
        frame.crestFactor >= config.impulseCrestFactor ||
        frame.highBandRatio >= config.impulseHighBandRatio ||
        frame.flatness >= config.impulseFlatness ||
        frame.clippingFraction >= config.impulseClippingFraction;
    final sudden = riseDb >= config.impulseRiseDb;
    final suppressed =
        _impulseSuppressUntil != null && atUtc.isBefore(_impulseSuppressUntil!);

    // Do not let a loud transient instantly redefine the ambient floor. The
    // capped update still lets the detector adapt gradually to a noisy room.
    final limitedDb = math.min(frame.db, baseline + 6);
    _ambientDb = baseline * 0.96 + limitedDb * 0.04;

    if (!loud || !transient || !sudden || suppressed) {
      return null;
    }
    _impulseSuppressUntil = atUtc.add(
      Duration(milliseconds: (config.impulseCooldownSeconds * 1000).round()),
    );

    final loudScore = math.max(
      ((frame.db + 30) / 30).clamp(0.0, 1.0),
      frame.peakAmplitude.clamp(0.0, 1.0),
    );
    final riseScore = (riseDb / 30).clamp(0.0, 1.0);
    final transientScore = math.max(
      ((frame.crestFactor - 1) / 8).clamp(0.0, 1.0),
      math.max(
        (frame.highBandRatio * 2).clamp(0.0, 1.0),
        math.max(
          frame.flatness.clamp(0.0, 1.0),
          (frame.clippingFraction * 20).clamp(0.0, 1.0),
        ),
      ),
    );
    final confidence =
        (0.4 * loudScore + 0.3 * riseScore + 0.3 * transientScore).clamp(
          0.55,
          0.99,
        );
    return AcousticDetection(
      kind: AcousticDetectionKind.suddenLoudNoise,
      startedAtUtc: atUtc,
      endedAtUtc: atUtc.add(
        Duration(milliseconds: (frameSeconds * 1000).round()),
      ),
      confidence: confidence,
      captureSessionId: captureSessionId,
      details: {
        'db': _round(frame.db),
        'riseDb': _round(riseDb),
        'peakAmplitude': _round(frame.peakAmplitude),
        'crestFactor': _round(frame.crestFactor),
        'highBandRatio': _round(frame.highBandRatio),
        'clippingFraction': _round(frame.clippingFraction),
        'classification': 'sudden loud acoustic event',
        'caveat': 'Not proof of an accident or its cause.',
      },
    );
  }

  List<AcousticDetection> _trackRaisedVoice(
    SpectralFrame frame,
    DateTime atUtc,
  ) {
    final voiceLike =
        frame.dominantHz >= 80 &&
        frame.dominantHz <= 3400 &&
        (frame.crest <= 180 ||
            frame.flatness >= 0.01 ||
            frame.highBandRatio >= 0.015);
    final candidate =
        frame.db >= config.raisedVoiceDb &&
        frame.speechBandRatio >= config.raisedVoiceSpeechBandRatio &&
        voiceLike;

    if (candidate) {
      _episodeStart ??= atUtc;
      _lastRaisedAt = atUtc;
      _candidateFrames++;
      _quietFrames = 0;
      _dbSum += frame.db;
      _speechBandSum += frame.speechBandRatio;
      _maxDb = math.max(_maxDb, frame.db);

      final candidateSeconds = _candidateFrames * frameSeconds;
      if (!_raisedEmitted && candidateSeconds >= config.raisedVoiceMinSeconds) {
        _raisedEmitted = true;
        final meanDb = _dbSum / _candidateFrames;
        final meanSpeechBand = _speechBandSum / _candidateFrames;
        final loudScore = ((meanDb - config.raisedVoiceDb) / 18).clamp(
          0.0,
          1.0,
        );
        final bandScore =
            ((meanSpeechBand - config.raisedVoiceSpeechBandRatio) / 0.45).clamp(
              0.0,
              1.0,
            );
        return [
          AcousticDetection(
            kind: AcousticDetectionKind.raisedVoice,
            startedAtUtc: _episodeStart!,
            endedAtUtc: atUtc,
            confidence: (0.62 + 0.2 * loudScore + 0.18 * bandScore).clamp(
              0.62,
              0.96,
            ),
            captureSessionId: captureSessionId,
            details: {
              'maxDb': _round(_maxDb),
              'meanDb': _round(meanDb),
              'speechBandRatio': _round(meanSpeechBand),
              'classification': 'sustained raised-voice-like energy',
              'caveat': 'May be speech, media, or another sound source.',
            },
          ),
        ];
      }
      return const [];
    }

    if (_episodeStart == null) {
      return const [];
    }
    _quietFrames++;
    if (_quietFrames * frameSeconds < config.raisedVoiceGapSeconds) {
      return const [];
    }
    return _finishEpisode(_lastRaisedAt ?? atUtc);
  }

  List<AcousticDetection> _finishEpisode(DateTime endedAtUtc) {
    final startedAt = _episodeStart;
    final wasRaised = _raisedEmitted;
    final maxDb = _maxDb;
    _clearEpisode();
    if (!wasRaised || startedAt == null) {
      return const [];
    }

    _recentBursts.add(
      _RaisedVoiceBurst(
        startedAtUtc: startedAt,
        endedAtUtc: endedAtUtc,
        maxDb: maxDb,
      ),
    );
    final cutoff = endedAtUtc.subtract(
      Duration(milliseconds: (config.argumentWindowSeconds * 1000).round()),
    );
    _recentBursts.removeWhere((burst) => burst.endedAtUtc.isBefore(cutoff));

    final suppressed =
        _argumentSuppressUntil != null &&
        endedAtUtc.isBefore(_argumentSuppressUntil!);
    if (_recentBursts.length < config.argumentMinBursts || suppressed) {
      return const [];
    }
    _argumentSuppressUntil = endedAtUtc.add(
      Duration(milliseconds: (config.argumentCooldownSeconds * 1000).round()),
    );
    final relevant = _recentBursts
        .skip(_recentBursts.length - config.argumentMinBursts)
        .toList(growable: false);
    final loudestDb = relevant.map((burst) => burst.maxDb).reduce(math.max);
    final densityScore = (relevant.length / (config.argumentMinBursts + 1))
        .clamp(0.0, 1.0);
    final loudScore = ((loudestDb - config.raisedVoiceDb) / 18).clamp(0.0, 1.0);
    return [
      AcousticDetection(
        kind: AcousticDetectionKind.possibleArgumentPattern,
        startedAtUtc: relevant.first.startedAtUtc,
        endedAtUtc: relevant.last.endedAtUtc,
        confidence: (0.58 + 0.2 * densityScore + 0.18 * loudScore).clamp(
          0.58,
          0.92,
        ),
        captureSessionId: captureSessionId,
        details: {
          'raisedVoiceBursts': relevant.length,
          'windowSeconds': config.argumentWindowSeconds,
          'loudestDb': _round(loudestDb),
          'classification': 'repeated raised-voice acoustic pattern',
          'caveat':
              'Not proof of an argument, the number of speakers, or identity.',
        },
      ),
    ];
  }

  void _clearEpisode() {
    _episodeStart = null;
    _lastRaisedAt = null;
    _candidateFrames = 0;
    _quietFrames = 0;
    _dbSum = 0;
    _speechBandSum = 0;
    _maxDb = -120;
    _raisedEmitted = false;
  }

  static double _round(double value) => double.parse(value.toStringAsFixed(3));
}

class _RaisedVoiceBurst {
  const _RaisedVoiceBurst({
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.maxDb,
  });

  final DateTime startedAtUtc;
  final DateTime endedAtUtc;
  final double maxDb;
}
