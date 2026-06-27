import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

/// Result of estimating the dominant cycle period of a slow signal.
class PeriodEstimate {
  const PeriodEstimate({
    required this.periodMinutes,
    required this.strength,
  });

  /// Estimated dominant period in minutes (0 when none could be found).
  final double periodMinutes;

  /// Relative strength of the dominant peak, 0..1 (fraction of in-band spectral
  /// power concentrated at the peak). A confidence proxy.
  final double strength;

  bool get isValid => periodMinutes > 0;
}

/// Estimates the dominant period of a slowly-varying signal (here: the per-epoch
/// sleep-depth envelope) using a Hann-windowed, zero-padded real FFT — the
/// frequency-domain analogue of "how often does the depth rise and fall?". A
/// peak inside the human sleep-cycle band ([minPeriodMinutes]..[maxPeriodMinutes])
/// is the night's cycle length.
///
/// Pure and synchronous; safe to call from an isolate. Returns an invalid
/// estimate when there isn't at least ~1.5 cycles of data to look at.
class SleepPeriodicityEstimator {
  const SleepPeriodicityEstimator({
    this.minPeriodMinutes = 60.0,
    this.maxPeriodMinutes = 130.0,
  });

  final double minPeriodMinutes;
  final double maxPeriodMinutes;

  PeriodEstimate estimate(List<double> samples, double stepMinutes) {
    final n = samples.length;
    if (n < 8 || stepMinutes <= 0) {
      return const PeriodEstimate(periodMinutes: 0, strength: 0);
    }
    final totalMinutes = n * stepMinutes;
    // Need enough span to see at least ~1.5 of the shortest cycle we'd report.
    if (totalMinutes < minPeriodMinutes * 1.5) {
      return const PeriodEstimate(periodMinutes: 0, strength: 0);
    }

    // Detrend (remove mean and linear trend) so a slow drift in baseline depth
    // doesn't masquerade as a very-long-period component.
    final detrended = _detrend(samples);

    // Hann window to suppress spectral leakage from the finite record.
    final windowed = Float64List(n);
    for (var i = 0; i < n; i++) {
      final w = n == 1 ? 1.0 : 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1)));
      windowed[i] = detrended[i] * w;
    }

    // Zero-pad to a power of two >= 4x the record for fine frequency resolution.
    final padded = _nextPow2(n * 4);
    final buf = Float64List(padded);
    for (var i = 0; i < n; i++) {
      buf[i] = windowed[i];
    }
    final power = FFT(padded).realFft(buf).discardConjugates().squareMagnitudes();

    // Bin k <-> period = padded * stepMinutes / k. Restrict to the cycle band.
    final kMinRaw = padded * stepMinutes / maxPeriodMinutes; // longest period
    final kMaxRaw = padded * stepMinutes / minPeriodMinutes; // shortest period
    final kLo = math.max(1, kMinRaw.floor());
    final kHi = math.min(power.length - 2, kMaxRaw.ceil());
    if (kHi <= kLo) {
      return const PeriodEstimate(periodMinutes: 0, strength: 0);
    }

    var peakK = kLo;
    var peakP = power[kLo];
    var bandTotal = 0.0;
    for (var k = kLo; k <= kHi; k++) {
      final p = power[k];
      bandTotal += p;
      if (p > peakP) {
        peakP = p;
        peakK = k;
      }
    }
    if (peakP <= 0 || bandTotal <= 0) {
      return const PeriodEstimate(periodMinutes: 0, strength: 0);
    }

    // Parabolic interpolation around the peak for sub-bin precision.
    final refinedK = _parabolicPeak(power, peakK);
    final periodMinutes = padded * stepMinutes / refinedK;
    // Strength = peak prominence over the band mean. Robust to zero-padding
    // (which spreads a single tone across several bins): ~1 for a clean periodic
    // signal, ~0 for flat/noisy spectra.
    final bandMean = bandTotal / (kHi - kLo + 1);
    final strength =
        bandMean <= 0 ? 0.0 : (1 - bandMean / peakP).clamp(0.0, 1.0);
    return PeriodEstimate(
      periodMinutes: periodMinutes.clamp(minPeriodMinutes, maxPeriodMinutes),
      strength: strength,
    );
  }

  static Float64List _detrend(List<double> x) {
    final n = x.length;
    // Least-squares line y = a + b*i.
    var sumI = 0.0, sumI2 = 0.0, sumY = 0.0, sumIY = 0.0;
    for (var i = 0; i < n; i++) {
      sumI += i;
      sumI2 += i * i.toDouble();
      sumY += x[i];
      sumIY += i * x[i];
    }
    final denom = n * sumI2 - sumI * sumI;
    final b = denom.abs() < 1e-9 ? 0.0 : (n * sumIY - sumI * sumY) / denom;
    final a = (sumY - b * sumI) / n;
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = x[i] - (a + b * i);
    }
    return out;
  }

  /// Refines the integer peak [k] to a fractional bin using a 3-point parabola.
  static double _parabolicPeak(Float64List power, int k) {
    if (k <= 0 || k >= power.length - 1) {
      return k.toDouble();
    }
    final alpha = power[k - 1];
    final beta = power[k];
    final gamma = power[k + 1];
    final denom = alpha - 2 * beta + gamma;
    if (denom.abs() < 1e-12) {
      return k.toDouble();
    }
    final delta = 0.5 * (alpha - gamma) / denom;
    return k + delta.clamp(-0.5, 0.5);
  }

  static int _nextPow2(int v) {
    var p = 1;
    while (p < v) {
      p <<= 1;
    }
    return p;
  }
}
