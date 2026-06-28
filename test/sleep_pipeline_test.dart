import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/services/acoustic/acoustic_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fftSize = 2048;
  const sampleRate = 16000;
  const frameSeconds = (fftSize ~/ 2) / sampleRate; // hop time

  Float64List quietFrame(math.Random rng) {
    final f = Float64List(fftSize);
    for (var i = 0; i < fftSize; i++) {
      f[i] = (rng.nextDouble() - 0.5) * 0.01; // very quiet noise
    }
    return f;
  }

  List<AcousticDetection> run(AcousticDetectorFlags flags, int frames) {
    final pipeline = AcousticPipeline(
      fftSize: fftSize,
      sampleRate: sampleRate,
      flags: flags,
    );
    final rng = math.Random(42);
    var clock = DateTime.utc(2026, 1, 1, 23);
    final out = <AcousticDetection>[];
    for (var i = 0; i < frames; i++) {
      out.addAll(pipeline.process(quietFrame(rng), clock));
      clock = clock.add(
        Duration(microseconds: (frameSeconds * 1e6).round()),
      );
    }
    out.addAll(pipeline.flush());
    return out;
  }

  test('sleep flag produces sleep epochs from quiet audio', () {
    // ~ two 30 s epochs worth of frames.
    final out = run(
      const AcousticDetectorFlags(snore: false, music: false, speech: false, sleep: true),
      950,
    );
    final epochs =
        out.where((e) => e.kind == AcousticDetectionKind.sleepEpoch);
    expect(epochs, isNotEmpty);
  });

  test('no sleep flag means no sleep telemetry', () {
    final out = run(
      const AcousticDetectorFlags(snore: true, music: false, speech: false),
      950,
    );
    expect(
      out.where((e) =>
          e.kind == AcousticDetectionKind.sleepEpoch ||
          e.kind == AcousticDetectionKind.sleepCycle),
      isEmpty,
    );
  });

  test('snore stays suppressed when only the sleep detector is requested', () {
    // snore:false + sleep:true runs snore internally to feed sleep, but must not
    // surface snore detections.
    final out = run(
      const AcousticDetectorFlags(snore: false, music: false, speech: false, sleep: true),
      950,
    );
    expect(
      out.where((e) => e.kind == AcousticDetectionKind.snore),
      isEmpty,
    );
  });
}
