import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/services/acoustic/sleep_cycle_detector.dart';
import 'package:audio_dashcam/src/services/acoustic/spectral_features.dart';
import 'package:flutter_test/flutter_test.dart';

const _light = SpectralFrame(
  rms: 0.006,
  db: -48,
  centroidHz: 820,
  flatness: 0.62,
  crest: 4,
  rolloffHz: 1500,
  dominantHz: 220,
  lowBandRatio: 0.12,
  speechBandRatio: 0.22,
  totalPower: 1,
);

const _arousal = SpectralFrame(
  rms: 0.04,
  db: -28,
  centroidHz: 2400,
  flatness: 0.78,
  crest: 2,
  rolloffHz: 4300,
  dominantHz: 1300,
  lowBandRatio: 0.05,
  speechBandRatio: 0.58,
  totalPower: 1,
);

SleepCycleDetector _detector() => SleepCycleDetector(
  frameSeconds: 60,
  config: const SleepCycleConfig(
    sleepOnsetMinutes: 3,
    bucketSeconds: 60,
    maxGapMinutes: 5,
  ),
);

bool _isCycle(AcousticDetection e) {
  if (e.kind != AcousticDetectionKind.sleepCycle &&
      e.kind != AcousticDetectionKind.sleepCycleAlarm) {
    return false;
  }
  final idx = e.details['cycleIndex'];
  return idx is int && idx >= 1;
}

void main() {
  final base = DateTime.utc(2026, 1, 1, 22);

  test('control: continuous sleep then arousal fires a cycle boundary', () {
    final d = _detector();
    final events = <AcousticDetection>[];
    for (var m = 0; m < 79; m++) {
      events.addAll(d.add(_light, base.add(Duration(minutes: m))));
    }
    // Arousal ~76 min after onset → a real cycle-1 boundary.
    events.addAll(d.add(_arousal, base.add(const Duration(minutes: 79))));
    events.addAll(d.add(_arousal, base.add(const Duration(minutes: 80))));
    events.addAll(d.flush());
    expect(events.where(_isCycle), isNotEmpty);
  });

  test('a long capture gap re-detects onset, suppressing a phantom cycle', () {
    final d = _detector();
    final events = <AcousticDetection>[];
    // ~40 min of sleep, then a 40-min capture gap (call/interruption), then an
    // arousal. Without gap handling this would look like a ~76-min cycle.
    for (var m = 0; m < 40; m++) {
      events.addAll(d.add(_light, base.add(Duration(minutes: m))));
    }
    events.addAll(d.add(_arousal, base.add(const Duration(minutes: 80))));
    events.addAll(d.add(_arousal, base.add(const Duration(minutes: 81))));
    events.addAll(d.flush());
    expect(events.where(_isCycle), isEmpty);
  });
}
