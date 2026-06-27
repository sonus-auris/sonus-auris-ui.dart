import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/services/acoustic/sleep_cycle_detector.dart';
import 'package:audio_dashcam/src/services/acoustic/spectral_features.dart';
import 'package:flutter_test/flutter_test.dart';

// Compressed timescale for tests: 0.5 s frames, 4 per 2 s epoch, but we advance
// the clock 1 minute per frame so cycle-length math (which uses timestamps)
// accrues quickly without feeding tens of thousands of real frames.
const double _frameSeconds = 0.5;
const _config = SleepConfig(
  epochSeconds: 2.0,
  depthSmoothingMinutes: 0.05,
  minCycleMinutes: 3.0,
  periodicityEveryEpochs: 1000,
);

SpectralFrame _deep() => const SpectralFrame(
      rms: 0.001,
      db: -60,
      centroidHz: 200,
      flatness: 0.2,
      crest: 50,
      rolloffHz: 350,
      dominantHz: 180,
      lowBandRatio: 0.6,
      speechBandRatio: 0.1,
      totalPower: 1,
    );

SpectralFrame _arousal() => const SpectralFrame(
      rms: 0.2,
      db: -25,
      centroidHz: 1500,
      flatness: 0.6,
      crest: 8,
      rolloffHz: 3000,
      dominantHz: 1200,
      lowBandRatio: 0.1,
      speechBandRatio: 0.4,
      totalPower: 5,
    );

void main() {
  late DateTime clock;
  late SleepCycleDetector detector;
  late List<AcousticDetection> events;

  setUp(() {
    clock = DateTime.utc(2026, 1, 1, 23, 0, 0);
    detector = SleepCycleDetector(frameSeconds: _frameSeconds, config: _config);
    events = [];
  });

  // Feed [epochs] epochs of [frame], advancing the clock 1 min per frame.
  void feed(SpectralFrame frame, int epochs) {
    final framesPerEpoch = (_config.epochSeconds / _frameSeconds).round();
    for (var e = 0; e < epochs; e++) {
      for (var f = 0; f < framesPerEpoch; f++) {
        events.addAll(detector.add(frame, clock, const []));
        clock = clock.add(const Duration(minutes: 1));
      }
    }
  }

  List<AcousticDetection> get cycles =>
      events.where((e) => e.kind == AcousticDetectionKind.sleepCycle).toList();
  List<AcousticDetection> get epochsOut =>
      events.where((e) => e.kind == AcousticDetectionKind.sleepEpoch).toList();

  test('descent into deep then arousal closes a cycle', () {
    feed(_deep(), 6); // descend + stay deep
    feed(_arousal(), 2); // arousal => boundary
    expect(cycles, hasLength(1));
    expect(cycles.first.details['cycleIndex'], 1);
    expect(cycles.first.details['lengthMinutes'] as double, greaterThan(3));
    // Epoch telemetry was emitted continuously, including deep stages.
    expect(epochsOut.length, greaterThan(4));
    expect(
      epochsOut.any((e) => e.details['stage'] == 'deep'),
      isTrue,
    );
  });

  test('multiple cycles are counted in order', () {
    for (var i = 0; i < 3; i++) {
      feed(_deep(), 6);
      feed(_arousal(), 2);
    }
    expect(cycles.length, greaterThanOrEqualTo(2));
    final indices =
        cycles.map((e) => e.details['cycleIndex'] as int).toList();
    for (var i = 1; i < indices.length; i++) {
      expect(indices[i], indices[i - 1] + 1);
    }
  });

  test('staying awake/noisy never closes a cycle (no descent)', () {
    feed(_arousal(), 10);
    expect(cycles, isEmpty);
  });

  test('a micro-arousal shorter than minCycle is not a boundary', () {
    feed(_deep(), 2); // ~brief
    feed(_arousal(), 1); // only ~1-2 min in -> below minCycle 3
    expect(cycles, isEmpty);
  });
}
