// Heuristic FFT music detector: flags loud, pitched, beat-carrying passages as music detections.
import '../../models/acoustic_detection.dart';
import 'spectral_features.dart';

/// Tunables for [MusicDetector].
class MusicConfig {
  const MusicConfig({
    this.windowSeconds = 6.0,
    this.loudDb = -45.0,
    this.pitchedFlatnessMax = 0.5,
    this.pitchedFractionMin = 0.5,
    this.beatStrengthMin = 0.3,
    this.minBeatPeriodSeconds = 0.3, // ~200 BPM
    this.maxBeatPeriodSeconds = 1.0, // ~60 BPM
    this.cooldownSeconds = 8.0,
  });

  final double windowSeconds;
  final double loudDb;

  /// Frames below this flatness are "pitched" (harmonic/tonal).
  final double pitchedFlatnessMax;

  /// Fraction of the window that must be pitched.
  final double pitchedFractionMin;

  /// Minimum normalized envelope-autocorrelation peak in the beat-lag range.
  final double beatStrengthMin;

  final double minBeatPeriodSeconds;
  final double maxBeatPeriodSeconds;

  /// After firing, suppress repeats for this long of continuous music.
  final double cooldownSeconds;
}

/// Flags sustained, rhythmic, pitched audio as music. Pure and stateful: feed
/// frames in order. Tempo is estimated from the autocorrelation of the loudness
/// envelope, so a steady single tone (no beat) does not trigger.
class MusicDetector {
  MusicDetector({
    required this.frameSeconds,
    this.config = const MusicConfig(),
    this.captureSessionId = '',
  }) : _capacity = (config.windowSeconds / frameSeconds).ceil().clamp(8, 4096);

  final double frameSeconds;
  final MusicConfig config;
  final String captureSessionId;
  final int _capacity;

  final List<double> _env = [];
  final List<bool> _pitched = [];
  final List<DateTime> _times = [];
  DateTime? _suppressUntil;

  /// Minimum envelope coefficient-of-variation squared (≈10% depth) before the
  /// autocorrelation is trusted.
  static const double _minModulationDepthSq = 0.01;

  List<AcousticDetection> add(SpectralFrame frame, DateTime atUtc) {
    _env.add(frame.rms);
    _pitched.add(frame.flatness <= config.pitchedFlatnessMax && frame.db >= config.loudDb);
    _times.add(atUtc);
    if (_env.length > _capacity) {
      _env.removeAt(0);
      _pitched.removeAt(0);
      _times.removeAt(0);
    }
    if (_env.length < _capacity) {
      return const [];
    }
    if (_suppressUntil != null && atUtc.isBefore(_suppressUntil!)) {
      return const [];
    }

    final pitchedFraction =
        _pitched.where((p) => p).length / _pitched.length;
    if (pitchedFraction < config.pitchedFractionMin) {
      return const [];
    }
    final beat = _beatStrength();
    if (beat < config.beatStrengthMin) {
      return const [];
    }
    _suppressUntil = atUtc.add(
      Duration(milliseconds: (config.cooldownSeconds * 1000).round()),
    );
    return [
      AcousticDetection(
        kind: AcousticDetectionKind.music,
        startedAtUtc: _times.first.toUtc(),
        endedAtUtc: atUtc.toUtc(),
        confidence: ((pitchedFraction + beat) / 2).clamp(0.0, 1.0),
        captureSessionId: captureSessionId,
        details: {
          'beatStrength': double.parse(beat.toStringAsFixed(2)),
          'pitchedFraction': double.parse(pitchedFraction.toStringAsFixed(2)),
        },
      ),
    ];
  }

  void reset() {
    _env.clear();
    _pitched.clear();
    _times.clear();
    _suppressUntil = null;
  }

  /// Peak normalized autocorrelation of the mean-removed envelope across lags
  /// corresponding to plausible musical tempos.
  double _beatStrength() {
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
    final minLag = (config.minBeatPeriodSeconds / frameSeconds).floor().clamp(1, n - 1);
    final maxLag = (config.maxBeatPeriodSeconds / frameSeconds).ceil().clamp(minLag, n - 1);
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
