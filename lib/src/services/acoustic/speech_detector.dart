// Heuristic FFT speech detector: flags loud, voiced-band, syllable-modulated audio as speech detections.
import '../../models/acoustic_detection.dart';
import 'spectral_features.dart';

/// Tunables for [SpeechDetector].
class SpeechConfig {
  const SpeechConfig({
    this.windowSeconds = 1.5,
    this.loudDb = -45.0,
    this.speechBandRatioMin = 0.45,
    this.speechFractionMin = 0.5,
    this.modulationStrengthMin = 0.25,
    this.minModulationHz = 3.0,
    this.maxModulationHz = 8.0,
    this.cooldownSeconds = 3.0,
  });

  final double windowSeconds;
  final double loudDb;

  /// A frame is "voiced-band" when at least this much power sits in 300–3400 Hz.
  final double speechBandRatioMin;

  /// Fraction of the window that must be voiced-band.
  final double speechFractionMin;

  /// Minimum normalized envelope-autocorrelation peak in the syllabic range.
  final double modulationStrengthMin;

  /// Syllabic amplitude-modulation band (Hz).
  final double minModulationHz;
  final double maxModulationHz;

  final double cooldownSeconds;
}

/// Flags speech by combining voiced-band dominance with 3–8 Hz syllabic
/// amplitude modulation. Pure and stateful; feed frames in order.
class SpeechDetector {
  SpeechDetector({
    required this.frameSeconds,
    this.config = const SpeechConfig(),
    this.captureSessionId = '',
  }) : _capacity = (config.windowSeconds / frameSeconds).ceil().clamp(8, 2048);

  final double frameSeconds;
  final SpeechConfig config;
  final String captureSessionId;
  final int _capacity;

  final List<double> _env = [];
  final List<bool> _voiced = [];
  final List<DateTime> _times = [];
  DateTime? _suppressUntil;

  /// Minimum envelope coefficient-of-variation squared (≈10% depth) before the
  /// autocorrelation is trusted.
  static const double _minModulationDepthSq = 0.01;

  List<AcousticDetection> add(SpectralFrame frame, DateTime atUtc) {
    _env.add(frame.rms);
    _voiced.add(
      frame.speechBandRatio >= config.speechBandRatioMin &&
          frame.db >= config.loudDb,
    );
    _times.add(atUtc);
    if (_env.length > _capacity) {
      _env.removeAt(0);
      _voiced.removeAt(0);
      _times.removeAt(0);
    }
    if (_env.length < _capacity) {
      return const [];
    }
    if (_suppressUntil != null && atUtc.isBefore(_suppressUntil!)) {
      return const [];
    }

    final voicedFraction = _voiced.where((v) => v).length / _voiced.length;
    if (voicedFraction < config.speechFractionMin) {
      return const [];
    }
    final modulation = _modulationStrength();
    if (modulation < config.modulationStrengthMin) {
      return const [];
    }
    _suppressUntil = atUtc.add(
      Duration(milliseconds: (config.cooldownSeconds * 1000).round()),
    );
    return [
      AcousticDetection(
        kind: AcousticDetectionKind.speech,
        startedAtUtc: _times.first.toUtc(),
        endedAtUtc: atUtc.toUtc(),
        confidence: ((voicedFraction + modulation) / 2).clamp(0.0, 1.0),
        captureSessionId: captureSessionId,
        details: {
          'voicedFraction': double.parse(voicedFraction.toStringAsFixed(2)),
          'modulation': double.parse(modulation.toStringAsFixed(2)),
        },
      ),
    ];
  }

  void reset() {
    _env.clear();
    _voiced.clear();
    _times.clear();
    _suppressUntil = null;
  }

  double _modulationStrength() {
    final n = _env.length;
    var mean = 0.0;
    for (final v in _env) {
      mean += v;
    }
    mean /= n;
    final x = List<double>.generate(n, (i) => _env[i] - mean);
    var energy = 0.0;
    for (final v in x) {
      energy += v * v;
    }
    // Require a real modulation depth: a flat envelope leaves only floating-point
    // residue, which autocorrelates spuriously high.
    if (mean <= 0 || energy / n < _minModulationDepthSq * mean * mean) {
      return 0;
    }
    // Modulation frequency f maps to lag = 1/(f*frameSeconds).
    final minLag = (1 / (config.maxModulationHz * frameSeconds)).floor().clamp(
      1,
      n - 1,
    );
    final maxLag = (1 / (config.minModulationHz * frameSeconds)).ceil().clamp(
      minLag,
      n - 1,
    );
    var best = 0.0;
    for (var lag = minLag; lag <= maxLag; lag++) {
      var sum = 0.0;
      for (var i = 0; i + lag < n; i++) {
        sum += x[i] * x[i + lag];
      }
      final r = sum / energy;
      if (r > best) {
        best = r;
      }
    }
    return best;
  }
}
