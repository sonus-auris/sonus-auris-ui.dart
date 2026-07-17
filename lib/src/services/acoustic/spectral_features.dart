// SpectralAnalyzer + SpectralFrame: per-frame frequency-domain features (centroid, flatness, band ratios) computed by FFT that every detector consumes.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

/// Per-frame frequency-domain summary produced by [SpectralAnalyzer].
///
/// All energy ratios are fractions of the frame's total spectral power (0..1),
/// so they are comparable across loud and quiet frames. [db] and [rms] describe
/// loudness in the time domain; everything else describes the spectrum shape.
class SpectralFrame {
  const SpectralFrame({
    required this.rms,
    required this.db,
    required this.centroidHz,
    required this.flatness,
    required this.crest,
    required this.rolloffHz,
    required this.dominantHz,
    required this.lowBandRatio,
    required this.speechBandRatio,
    required this.totalPower,
    this.peakAmplitude = 0,
    this.crestFactor = 0,
    this.highBandRatio = 0,
    this.clippingFraction = 0,
  });

  /// Time-domain RMS of the frame, normalized to 0..1 (full scale == 1).
  final double rms;

  /// RMS expressed in dBFS, clamped to a -120 floor.
  final double db;

  /// Largest absolute time-domain sample, normalized to 0..1.
  final double peakAmplitude;

  /// Time-domain peak divided by RMS. Impulses have a much larger crest factor
  /// than sustained tones or continuously loud ambience.
  final double crestFactor;

  /// Fraction of samples at or above 98% full scale. This is evidence of input
  /// clipping, which is useful context for loud-event confidence and QA.
  final double clippingFraction;

  /// Power-weighted mean frequency (Hz). Low for rumble/snoring, higher for
  /// hiss/speech consonants.
  final double centroidHz;

  /// Spectral flatness (geometric mean / arithmetic mean of the power spectrum),
  /// 0..1. Near 1 for noise-like signals, near 0 for tonal/pitched signals.
  final double flatness;

  /// Spectral crest (peak power / mean power). High for strongly tonal content
  /// such as a sustained musical note.
  final double crest;

  /// Frequency below which 85% of the spectral power lies (Hz).
  final double rolloffHz;

  /// Frequency of the single strongest bin (Hz).
  final double dominantHz;

  /// Fraction of total power in the 60–300 Hz band (snore fundamental region).
  final double lowBandRatio;

  /// Fraction of total power in the 300–3400 Hz telephone speech band.
  final double speechBandRatio;

  /// Fraction of total power above the speech band (3400 Hz to Nyquist).
  /// Broadband impacts, shattering sounds, and hiss tend to raise this value.
  final double highBandRatio;

  /// Sum of bin powers — absolute, not normalized.
  final double totalPower;
}

/// Computes [SpectralFrame]s from fixed-size mono frames using a Hann-windowed
/// real FFT. Pure and synchronous: hold one instance per [fftSize]/[sampleRate]
/// pair and reuse it (the FFT plan and window are cached). No I/O, so this is
/// directly unit-testable and safe to run inside an isolate.
class SpectralAnalyzer {
  SpectralAnalyzer({required this.fftSize, required this.sampleRate})
    : assert(
        fftSize > 0 && (fftSize & (fftSize - 1)) == 0,
        'fftSize must be a power of two',
      ),
      _fft = FFT(fftSize),
      _window = _hann(fftSize),
      _binHz = sampleRate / fftSize;

  final int fftSize;
  final int sampleRate;
  final FFT _fft;
  final Float64List _window;
  final double _binHz;

  static const double _epsilon = 1e-12;
  static const double _dbFloor = -120.0;

  /// Lowest and highest band edges of interest.
  static const double _lowBandLowHz = 60;
  static const double _lowBandHighHz = 300;
  static const double _speechLowHz = 300;
  static const double _speechHighHz = 3400;
  static const double _clippingAmplitude = 0.98;

  /// Analyzes a single frame of normalized (-1..1) mono samples. The frame must
  /// be exactly [fftSize] long.
  SpectralFrame analyze(Float64List frame) {
    if (frame.length != fftSize) {
      throw ArgumentError('frame length ${frame.length} != fftSize $fftSize');
    }
    // Time-domain RMS from the raw (un-windowed) frame.
    var sumSquares = 0.0;
    var peakAmplitude = 0.0;
    var clippedSamples = 0;
    for (var i = 0; i < fftSize; i++) {
      final s = frame[i];
      final magnitude = s.abs();
      sumSquares += s * s;
      if (magnitude > peakAmplitude) {
        peakAmplitude = magnitude;
      }
      if (magnitude >= _clippingAmplitude) {
        clippedSamples++;
      }
    }
    final rms = math.sqrt(sumSquares / fftSize);
    final db = rms <= 0
        ? _dbFloor
        : (20 * math.log(rms) / math.ln10).clamp(_dbFloor, 0.0);
    final crestFactor = rms <= _epsilon ? 0.0 : peakAmplitude / rms;
    final clippingFraction = clippedSamples / fftSize;

    // Windowed copy for the spectral estimate.
    final windowed = Float64List(fftSize);
    for (var i = 0; i < fftSize; i++) {
      windowed[i] = frame[i] * _window[i];
    }
    final spectrum = _fft.realFft(windowed).discardConjugates();
    final power = spectrum.squareMagnitudes();
    final bins = power.length; // fftSize/2 + 1

    var total = 0.0;
    var weightedFreq = 0.0;
    var logSum = 0.0;
    var peak = 0.0;
    var peakIndex = 0;
    var lowBand = 0.0;
    var speechBand = 0.0;
    var highBand = 0.0;
    for (var i = 0; i < bins; i++) {
      final p = power[i];
      final freq = i * _binHz;
      total += p;
      weightedFreq += freq * p;
      logSum += math.log(p + _epsilon);
      if (p > peak) {
        peak = p;
        peakIndex = i;
      }
      if (freq >= _lowBandLowHz && freq <= _lowBandHighHz) {
        lowBand += p;
      }
      if (freq >= _speechLowHz && freq <= _speechHighHz) {
        speechBand += p;
      }
      if (freq > _speechHighHz) {
        highBand += p;
      }
    }

    if (total <= _epsilon) {
      return SpectralFrame(
        rms: rms,
        db: db,
        centroidHz: 0,
        flatness: 1,
        crest: 1,
        rolloffHz: 0,
        dominantHz: 0,
        lowBandRatio: 0,
        speechBandRatio: 0,
        totalPower: total,
        peakAmplitude: peakAmplitude,
        crestFactor: crestFactor,
        highBandRatio: 0,
        clippingFraction: clippingFraction,
      );
    }

    final centroid = weightedFreq / total;
    final geoMean = math.exp(logSum / bins);
    final arithMean = total / bins;
    final flatness = (geoMean / (arithMean + _epsilon)).clamp(0.0, 1.0);
    final crest = peak / (arithMean + _epsilon);

    // 85% spectral rolloff.
    final rolloffTarget = 0.85 * total;
    var cumulative = 0.0;
    var rolloffIndex = bins - 1;
    for (var i = 0; i < bins; i++) {
      cumulative += power[i];
      if (cumulative >= rolloffTarget) {
        rolloffIndex = i;
        break;
      }
    }

    return SpectralFrame(
      rms: rms,
      db: db,
      centroidHz: centroid,
      flatness: flatness,
      crest: crest,
      rolloffHz: rolloffIndex * _binHz,
      dominantHz: peakIndex * _binHz,
      lowBandRatio: lowBand / total,
      speechBandRatio: speechBand / total,
      totalPower: total,
      peakAmplitude: peakAmplitude,
      crestFactor: crestFactor,
      highBandRatio: highBand / total,
      clippingFraction: clippingFraction,
    );
  }

  static Float64List _hann(int n) {
    final w = Float64List(n);
    if (n == 1) {
      w[0] = 1;
      return w;
    }
    for (var i = 0; i < n; i++) {
      w[i] = 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1)));
    }
    return w;
  }
}

/// Converts interleaved little-endian PCM16 bytes to normalized mono doubles in
/// -1..1, averaging channels. Shared by the recorder feed and tests.
Float64List pcm16BytesToMonoDoubles(Uint8List bytes, int channels) {
  final frameSize = channels * 2;
  if (frameSize <= 0 || bytes.length < frameSize) {
    return Float64List(0);
  }
  final frames = bytes.length ~/ frameSize;
  final out = Float64List(frames);
  final view = ByteData.sublistView(bytes);
  for (var f = 0; f < frames; f++) {
    var sum = 0;
    for (var c = 0; c < channels; c++) {
      sum += view.getInt16((f * channels + c) * 2, Endian.little);
    }
    out[f] = (sum / channels) / 32768.0;
  }
  return out;
}
