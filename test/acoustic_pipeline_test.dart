import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/services/acoustic/acoustic_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

const int _sampleRate = 16000;
const int _fftSize = 2048;

/// Builds a mono signal by concatenating segments, each described by a sample
/// generator over its local time `t` (seconds).
Float64List _build(
  List<({double seconds, double Function(double t) gen})> parts,
) {
  final samples = <double>[];
  for (final part in parts) {
    final n = (part.seconds * _sampleRate).round();
    for (var i = 0; i < n; i++) {
      samples.add(part.gen(i / _sampleRate));
    }
  }
  return Float64List.fromList(samples);
}

double _tone(double t, double freq, {double amp = 0.5}) =>
    amp * math.sin(2 * math.pi * freq * t);

/// Feeds a full signal through the slicer + pipeline in 0.1s chunks.
List<AcousticDetection> _drive(Float64List signal, AcousticPipeline pipeline) {
  final slicer = FrameSlicer(fftSize: _fftSize, sampleRate: _sampleRate);
  final base = DateTime.utc(2026, 1, 1, 3, 0, 0);
  final out = <AcousticDetection>[];
  const chunk = 1600; // 0.1s
  for (var off = 0; off < signal.length; off += chunk) {
    final end = math.min(off + chunk, signal.length);
    final slice = Float64List.sublistView(signal, off, end);
    final at = base.add(
      Duration(microseconds: (off * 1e6 / _sampleRate).round()),
    );
    for (final framed in slicer.add(slice, at)) {
      out.addAll(pipeline.process(framed.frame, framed.atUtc));
    }
  }
  out.addAll(pipeline.flush());
  return out;
}

void main() {
  test(
    'low-frequency tonal bursts are detected as snoring through real FFT',
    () {
      final parts = <({double seconds, double Function(double t) gen})>[];
      for (var i = 0; i < 4; i++) {
        parts.add((seconds: 1.0, gen: (t) => _tone(t, 150)));
        parts.add((seconds: 3.0, gen: (_) => 0.0));
      }
      final pipeline = AcousticPipeline(
        fftSize: _fftSize,
        sampleRate: _sampleRate,
        flags: const AcousticDetectorFlags(
          snore: true,
          music: false,
          speech: false,
        ),
      );
      final events = _drive(_build(parts), pipeline);
      final snores = events
          .where((e) => e.kind == AcousticDetectionKind.snore)
          .toList();
      expect(snores.length, greaterThanOrEqualTo(3));
    },
  );

  test('pitched harmonic audio with a ~2 Hz beat is detected as music', () {
    // Three harmonics (tonal) gated by a 2 Hz pulse envelope.
    double gen(double t) {
      final beat = (t * 2).floor() % 1 == 0 && (t * 2 - (t * 2).floor()) < 0.5
          ? 1.0
          : 0.2;
      final tone =
          _tone(t, 440, amp: 0.3) +
          _tone(t, 880, amp: 0.2) +
          _tone(t, 1320, amp: 0.1);
      return beat * tone;
    }

    final signal = _build([(seconds: 9.0, gen: gen)]);
    final pipeline = AcousticPipeline(
      fftSize: _fftSize,
      sampleRate: _sampleRate,
      flags: const AcousticDetectorFlags(
        snore: false,
        music: true,
        speech: false,
      ),
    );
    final events = _drive(signal, pipeline);
    expect(
      events.where((e) => e.kind == AcousticDetectionKind.music),
      isNotEmpty,
    );
  });

  test('silence produces no detections', () {
    final signal = _build([(seconds: 10.0, gen: (_) => 0.0)]);
    final pipeline = AcousticPipeline(
      fftSize: _fftSize,
      sampleRate: _sampleRate,
    );
    expect(_drive(signal, pipeline), isEmpty);
  });

  test('a single full-scale impulse survives the FFT pipeline', () {
    final signal = Float64List(_sampleRate);
    signal[_sampleRate ~/ 2] = 1;
    final pipeline = AcousticPipeline(
      fftSize: _fftSize,
      sampleRate: _sampleRate,
      flags: const AcousticDetectorFlags(
        snore: false,
        sleep: false,
        music: false,
        speech: false,
        safety: true,
      ),
    );

    final events = _drive(signal, pipeline);
    expect(
      events.where(
        (event) => event.kind == AcousticDetectionKind.suddenLoudNoise,
      ),
      hasLength(1),
    );
  });

  test('repeated loud voice-like bursts form a possible argument pattern', () {
    double raisedVoice(double t) {
      return 0.32 * _tone(t, 440) +
          0.24 * _tone(t, 660) +
          0.16 * _tone(t, 880) +
          0.1 * _tone(t, 1760) +
          0.08 * _tone(t, 3520);
    }

    final signal = _build([
      for (var i = 0; i < 3; i++) ...[
        (seconds: 0.8, gen: raisedVoice),
        (seconds: 0.4, gen: (_) => 0.0),
      ],
    ]);
    final pipeline = AcousticPipeline(
      fftSize: _fftSize,
      sampleRate: _sampleRate,
      flags: const AcousticDetectorFlags(
        snore: false,
        sleep: false,
        music: false,
        speech: false,
        safety: true,
      ),
    );

    final events = _drive(signal, pipeline);
    expect(
      events.where((event) => event.kind == AcousticDetectionKind.raisedVoice),
      hasLength(3),
    );
    expect(
      events.where(
        (event) => event.kind == AcousticDetectionKind.possibleArgumentPattern,
      ),
      hasLength(1),
    );
  });
}
