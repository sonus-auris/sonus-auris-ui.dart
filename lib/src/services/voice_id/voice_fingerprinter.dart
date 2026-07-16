// FFT → mel filterbank → MFCC speaker fingerprints for "Knows your voice".
//
// Everything here is pure DSP over PCM that already lives on the device; no
// audio or fingerprint ever needs to leave it. A fingerprint is the L2
// normalized mean+standard deviation of per-frame MFCC vectors — the
// "transformed state" that is persisted so live matching never has to re-read
// or re-transform the enrolled WAV clips.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

/// Turns a mono PCM clip into a compact speaker fingerprint.
///
/// Pipeline per frame: pre-emphasis → Hann window → real FFT (fftea, the same
/// engine as [SpectralAnalyzer]) → power spectrum → triangular mel filterbank
/// (log energies) → DCT-II → MFCCs. Quiet frames are dropped by a simple
/// energy gate so silence between words doesn't dilute the voice statistics;
/// the clip-level fingerprint is the mean and standard deviation of each MFCC
/// coefficient across the voiced frames, L2 normalized so cosine similarity is
/// a plain dot product.
///
/// Pure and synchronous — hold one instance and reuse it (FFT plan, window,
/// filterbank, and DCT matrix are cached).
class VoiceFingerprinter {
  VoiceFingerprinter({
    this.sampleRate = 16000,
    this.fftSize = 512,
    this.hopSize = 256,
    this.melBands = 24,
    this.mfccCount = 13,
    this.minVoicedFrames = 25,
  }) : assert(
         fftSize > 0 && (fftSize & (fftSize - 1)) == 0,
         'fftSize must be a power of two',
       ),
       _fft = FFT(fftSize),
       _window = _hann(fftSize) {
    _filterbank = _melFilterbank(
      bands: melBands,
      fftSize: fftSize,
      sampleRate: sampleRate,
      lowHz: 80,
      highHz: math.min(4000, sampleRate / 2),
    );
    _dct = _dctMatrix(rows: mfccCount, columns: melBands);
  }

  final int sampleRate;
  final int fftSize;
  final int hopSize;
  final int melBands;
  final int mfccCount;

  /// Fewest voiced frames a clip must contain to yield a fingerprint
  /// (25 frames ≈ 0.4 s of actual speech at the default hop).
  final int minVoicedFrames;

  final FFT _fft;
  final Float64List _window;
  late final List<Float64List> _filterbank;
  late final List<Float64List> _dct;

  static const double _epsilon = 1e-10;
  static const double _preEmphasis = 0.97;

  /// Length of the vectors [fingerprint] produces (mean + std per MFCC).
  int get fingerprintLength => mfccCount * 2;

  /// Computes the clip fingerprint, or null when the clip holds too little
  /// voiced audio to characterize a speaker.
  List<double>? fingerprint(Float64List mono) {
    if (mono.length < fftSize) {
      return null;
    }
    // Pre-emphasis balances the spectral tilt of speech so the higher formants
    // that distinguish voices carry weight in the mel energies.
    final emphasized = Float64List(mono.length);
    emphasized[0] = mono[0];
    for (var i = 1; i < mono.length; i++) {
      emphasized[i] = mono[i] - _preEmphasis * mono[i - 1];
    }

    // First pass: frame RMS values for the energy gate.
    final frameCount = 1 + (mono.length - fftSize) ~/ hopSize;
    final frameRms = Float64List(frameCount);
    var peakRms = 0.0;
    for (var f = 0; f < frameCount; f++) {
      final start = f * hopSize;
      var sum = 0.0;
      for (var i = 0; i < fftSize; i++) {
        final s = mono[start + i];
        sum += s * s;
      }
      final rms = math.sqrt(sum / fftSize);
      frameRms[f] = rms;
      if (rms > peakRms) {
        peakRms = rms;
      }
    }
    // Voiced = clearly above the absolute noise floor and not vanishingly
    // quiet relative to the clip's own loudest frame.
    final gate = math.max(0.004, 0.15 * peakRms);

    final mfccFrames = <Float64List>[];
    final windowed = Float64List(fftSize);
    for (var f = 0; f < frameCount; f++) {
      if (frameRms[f] < gate) {
        continue;
      }
      final start = f * hopSize;
      for (var i = 0; i < fftSize; i++) {
        windowed[i] = emphasized[start + i] * _window[i];
      }
      final power = _fft
          .realFft(windowed)
          .discardConjugates()
          .squareMagnitudes();
      final logMel = Float64List(melBands);
      for (var b = 0; b < melBands; b++) {
        final filter = _filterbank[b];
        var energy = 0.0;
        for (var i = 0; i < filter.length; i++) {
          energy += filter[i] * power[i];
        }
        logMel[b] = math.log(energy + _epsilon);
      }
      final mfcc = Float64List(mfccCount);
      for (var c = 0; c < mfccCount; c++) {
        final row = _dct[c];
        var acc = 0.0;
        for (var b = 0; b < melBands; b++) {
          acc += row[b] * logMel[b];
        }
        mfcc[c] = acc;
      }
      mfccFrames.add(Float64List.fromList(mfcc));
    }
    if (mfccFrames.length < minVoicedFrames) {
      return null;
    }

    final mean = Float64List(mfccCount);
    for (final frame in mfccFrames) {
      for (var c = 0; c < mfccCount; c++) {
        mean[c] += frame[c];
      }
    }
    for (var c = 0; c < mfccCount; c++) {
      mean[c] /= mfccFrames.length;
    }
    final std = Float64List(mfccCount);
    for (final frame in mfccFrames) {
      for (var c = 0; c < mfccCount; c++) {
        final d = frame[c] - mean[c];
        std[c] += d * d;
      }
    }
    for (var c = 0; c < mfccCount; c++) {
      std[c] = math.sqrt(std[c] / mfccFrames.length);
    }

    final vector = List<double>.filled(fingerprintLength, 0);
    for (var c = 0; c < mfccCount; c++) {
      vector[c] = mean[c];
      vector[mfccCount + c] = std[c];
    }
    var norm = 0.0;
    for (final v in vector) {
      norm += v * v;
    }
    norm = math.sqrt(norm);
    if (norm <= _epsilon) {
      return null;
    }
    for (var i = 0; i < vector.length; i++) {
      vector[i] /= norm;
    }
    return vector;
  }

  /// Cosine similarity in [-1, 1]; both fingerprints are already unit-norm so
  /// this is a dot product. Returns 0 for mismatched lengths.
  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) {
      return 0;
    }
    var dot = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot.clamp(-1.0, 1.0);
  }

  /// Naive decimating resampler good enough for voiceprints: averages the
  /// source samples covered by each output sample. Only downsamples; input
  /// already at (or below) [targetRate] is returned unchanged.
  static Float64List downsample(
    Float64List mono,
    int sourceRate,
    int targetRate,
  ) {
    if (sourceRate <= targetRate || mono.isEmpty) {
      return mono;
    }
    final ratio = sourceRate / targetRate;
    final outLength = (mono.length / ratio).floor();
    final out = Float64List(outLength);
    for (var i = 0; i < outLength; i++) {
      final start = (i * ratio).floor();
      final end = math.min(((i + 1) * ratio).ceil(), mono.length);
      var sum = 0.0;
      for (var j = start; j < end; j++) {
        sum += mono[j];
      }
      out[i] = end > start ? sum / (end - start) : 0;
    }
    return out;
  }

  static Float64List _hann(int size) {
    final window = Float64List(size);
    for (var i = 0; i < size; i++) {
      window[i] = 0.5 * (1 - math.cos(2 * math.pi * i / (size - 1)));
    }
    return window;
  }

  static double _hzToMel(double hz) =>
      2595 * math.log(1 + hz / 700) / math.ln10;

  static double _melToHz(double mel) =>
      700 * (math.pow(10, mel / 2595) - 1).toDouble();

  /// Triangular mel filters over the one-sided power spectrum
  /// (fftSize/2 + 1 bins).
  static List<Float64List> _melFilterbank({
    required int bands,
    required int fftSize,
    required int sampleRate,
    required double lowHz,
    required double highHz,
  }) {
    final bins = fftSize ~/ 2 + 1;
    final lowMel = _hzToMel(lowHz);
    final highMel = _hzToMel(highHz);
    final centers = List<double>.generate(
      bands + 2,
      (i) => _melToHz(lowMel + (highMel - lowMel) * i / (bands + 1)),
    );
    final binHz = sampleRate / fftSize;
    final filters = <Float64List>[];
    for (var b = 0; b < bands; b++) {
      final left = centers[b];
      final center = centers[b + 1];
      final right = centers[b + 2];
      final filter = Float64List(bins);
      for (var i = 0; i < bins; i++) {
        final freq = i * binHz;
        if (freq >= left && freq <= center && center > left) {
          filter[i] = (freq - left) / (center - left);
        } else if (freq > center && freq <= right && right > center) {
          filter[i] = (right - freq) / (right - center);
        }
      }
      filters.add(filter);
    }
    return filters;
  }

  /// DCT-II rows 1..[rows] (row 0 — overall log energy — is deliberately
  /// skipped: it tracks loudness, not voice identity).
  static List<Float64List> _dctMatrix({
    required int rows,
    required int columns,
  }) {
    final matrix = <Float64List>[];
    for (var r = 1; r <= rows; r++) {
      final row = Float64List(columns);
      for (var c = 0; c < columns; c++) {
        row[c] =
            math.cos(math.pi * r * (c + 0.5) / columns) *
            math.sqrt(2 / columns);
      }
      matrix.add(row);
    }
    return matrix;
  }
}
