import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_dashcam/src/services/acoustic/spectral_features.dart';
import 'package:flutter_test/flutter_test.dart';

Float64List _sine(double freqHz, int sampleRate, int n, {double amp = 0.5}) {
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    out[i] = amp * math.sin(2 * math.pi * freqHz * i / sampleRate);
  }
  return out;
}

Float64List _whiteNoise(int n, {double amp = 0.3, int seed = 7}) {
  final rng = math.Random(seed);
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    out[i] = amp * (rng.nextDouble() * 2 - 1);
  }
  return out;
}

void main() {
  const sampleRate = 16000;
  const fftSize = 2048;
  final analyzer = SpectralAnalyzer(fftSize: fftSize, sampleRate: sampleRate);
  final binHz = sampleRate / fftSize;

  test('rejects wrong-length frames', () {
    expect(
      () => analyzer.analyze(Float64List(fftSize - 1)),
      throwsArgumentError,
    );
  });

  test('requires power-of-two fft size', () {
    expect(
      () => SpectralAnalyzer(fftSize: 1000, sampleRate: sampleRate),
      throwsA(isA<AssertionError>()),
    );
  });

  test('pure tone is tonal: low flatness, high crest, dominant near tone', () {
    final frame = _sine(200, sampleRate, fftSize);
    final f = analyzer.analyze(frame);
    expect(f.dominantHz, closeTo(200, binHz));
    expect(f.flatness, lessThan(0.05));
    expect(f.crest, greaterThan(50));
    // A 200 Hz tone sits inside the snore low band, not the speech band.
    expect(f.lowBandRatio, greaterThan(0.8));
    expect(f.speechBandRatio, lessThan(0.2));
    expect(f.centroidHz, closeTo(200, 80));
  });

  test('white noise is flat and broadband', () {
    final f = analyzer.analyze(_whiteNoise(fftSize));
    expect(f.flatness, greaterThan(0.2));
    expect(f.crest, lessThan(30));
    // Energy is spread, so the centroid sits well above the snore band.
    expect(f.centroidHz, greaterThan(2000));
  });

  test('speech-band tone lands in the speech band', () {
    final f = analyzer.analyze(_sine(1500, sampleRate, fftSize));
    expect(f.dominantHz, closeTo(1500, binHz));
    expect(f.speechBandRatio, greaterThan(0.8));
    expect(f.lowBandRatio, lessThan(0.1));
  });

  test('high-frequency tone lands above the speech band', () {
    final f = analyzer.analyze(_sine(6000, sampleRate, fftSize));
    expect(f.dominantHz, closeTo(6000, binHz));
    expect(f.highBandRatio, greaterThan(0.8));
    expect(f.speechBandRatio, lessThan(0.1));
  });

  test('time-domain peak, crest factor, and clipping expose impulses', () {
    final impulse = Float64List(fftSize)..[fftSize ~/ 2] = 1;
    final f = analyzer.analyze(impulse);
    expect(f.peakAmplitude, 1);
    expect(f.crestFactor, closeTo(math.sqrt(fftSize), 0.01));
    expect(f.clippingFraction, closeTo(1 / fftSize, 1e-9));
  });

  test('dBFS tracks amplitude; silence hits the floor', () {
    final loud = analyzer.analyze(_sine(440, sampleRate, fftSize, amp: 0.9));
    final quiet = analyzer.analyze(_sine(440, sampleRate, fftSize, amp: 0.05));
    expect(loud.db, greaterThan(quiet.db));
    expect(loud.db, lessThanOrEqualTo(0));
    expect(loud.peakAmplitude, closeTo(0.9, 0.001));
    expect(loud.crestFactor, closeTo(math.sqrt(2), 0.01));
    expect(loud.clippingFraction, 0);
    final silent = analyzer.analyze(Float64List(fftSize));
    expect(silent.db, -120.0);
    expect(silent.rms, 0.0);
  });

  test('pcm16 bytes decode to normalized mono doubles', () {
    // Two stereo frames: L/R = (+full scale, 0) then (0, -full scale).
    final bytes = Uint8List(8);
    final view = ByteData.sublistView(bytes);
    view.setInt16(0, 32767, Endian.little);
    view.setInt16(2, 0, Endian.little);
    view.setInt16(4, 0, Endian.little);
    view.setInt16(6, -32768, Endian.little);
    final mono = pcm16BytesToMonoDoubles(bytes, 2);
    expect(mono.length, 2);
    expect(mono[0], closeTo(0.5, 0.001));
    expect(mono[1], closeTo(-0.5, 0.001));
  });
}
