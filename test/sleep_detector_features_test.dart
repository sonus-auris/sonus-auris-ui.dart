import 'dart:math' as math;

import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/services/acoustic/sleep_cycle_detector.dart';
import 'package:audio_dashcam/src/services/acoustic/spectral_features.dart';
import 'package:flutter_test/flutter_test.dart';

const double _frameSeconds = 2048 / 2 / 16000; // ~0.064 s

// A quiet, deep-sleep-shaped frame with a given total power (the breathing
// envelope rides on total power, which we modulate).
SpectralFrame _frame(double totalPower) => SpectralFrame(
      rms: 0.001,
      db: -55,
      centroidHz: 200,
      flatness: 0.2,
      crest: 50,
      rolloffHz: 350,
      dominantHz: 180,
      lowBandRatio: 0.6,
      speechBandRatio: 0.1,
      totalPower: totalPower,
    );

void main() {
  test('estimates breathing rate from a modulated low band', () {
    const config = SleepConfig(epochSeconds: 12.0);
    final detector = SleepCycleDetector(frameSeconds: _frameSeconds, config: config);
    final framesPerEpoch = (config.epochSeconds / _frameSeconds).round();
    var clock = DateTime.utc(2026, 1, 1, 23);
    const breathPeriod = 4.0; // seconds → 15 breaths/min
    final out = <AcousticDetection>[];
    for (var i = 0; i < framesPerEpoch; i++) {
      final t = i * _frameSeconds;
      final power = 1.0 + 0.8 * math.sin(2 * math.pi * t / breathPeriod);
      out.addAll(detector.add(_frame(power), clock, const []));
      clock = clock.add(
        Duration(microseconds: (_frameSeconds * 1e6).round()),
      );
    }
    final epoch = out.firstWhere(
      (e) => e.kind == AcousticDetectionKind.sleepEpoch,
    );
    final bpm = epoch.details['breathingRateBpm'] as double;
    final reg = epoch.details['breathingRegularity'] as double;
    expect(bpm, closeTo(15, 4));
    expect(reg, greaterThan(0.3));
  });

  test('flush emits the in-progress (partial) epoch', () {
    final detector = SleepCycleDetector(
      frameSeconds: _frameSeconds,
      config: const SleepConfig(epochSeconds: 30.0),
    );
    var clock = DateTime.utc(2026, 1, 1, 23);
    // Only ~50 frames << one 30 s epoch, so nothing emits yet.
    final mid = <AcousticDetection>[];
    for (var i = 0; i < 50; i++) {
      mid.addAll(detector.add(_frame(1.0), clock, const []));
      clock = clock.add(
        Duration(microseconds: (_frameSeconds * 1e6).round()),
      );
    }
    expect(mid, isEmpty);
    final flushed = detector.flush();
    expect(
      flushed.where((e) => e.kind == AcousticDetectionKind.sleepEpoch),
      hasLength(1),
    );
  });

  test('depth envelope gains one sample per closed epoch', () {
    const config = SleepConfig(epochSeconds: 5.0);
    final detector = SleepCycleDetector(frameSeconds: _frameSeconds, config: config);
    final framesPerEpoch = (config.epochSeconds / _frameSeconds).round();
    var clock = DateTime.utc(2026, 1, 1, 23);
    for (var e = 0; e < 4; e++) {
      for (var i = 0; i < framesPerEpoch; i++) {
        detector.add(_frame(1.0), clock, const []);
        clock = clock.add(
          Duration(microseconds: (_frameSeconds * 1e6).round()),
        );
      }
    }
    expect(detector.depthEnvelope, hasLength(4));
    for (final d in detector.depthEnvelope) {
      expect(d, inInclusiveRange(0.0, 1.0));
    }
  });
}
