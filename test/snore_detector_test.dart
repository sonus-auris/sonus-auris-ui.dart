import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/services/acoustic/snore_detector.dart';
import 'package:audio_dashcam/src/services/acoustic/spectral_features.dart';
import 'package:flutter_test/flutter_test.dart';

const double _frameSeconds = 2048 / 2 / 16000; // 0.064s

SpectralFrame _snoreFrame() => const SpectralFrame(
  rms: 0.3,
  db: -20,
  centroidHz: 200,
  flatness: 0.2,
  crest: 100,
  rolloffHz: 350,
  dominantHz: 180,
  lowBandRatio: 0.7,
  speechBandRatio: 0.1,
  totalPower: 1,
);

SpectralFrame _quietFrame() => const SpectralFrame(
  rms: 0,
  db: -120,
  centroidHz: 0,
  flatness: 1,
  crest: 1,
  rolloffHz: 0,
  dominantHz: 0,
  lowBandRatio: 0,
  speechBandRatio: 0,
  totalPower: 0,
);

void main() {
  late DateTime clock;
  late SnoreDetector detector;
  late List<AcousticDetection> events;

  setUp(() {
    clock = DateTime.utc(2026, 1, 1, 2, 0, 0);
    detector = SnoreDetector(frameSeconds: _frameSeconds);
    events = [];
  });

  void feed(SpectralFrame frame, double seconds) {
    final frames = (seconds / _frameSeconds).round();
    for (var i = 0; i < frames; i++) {
      events.addAll(detector.add(frame, clock));
      clock = clock.add(Duration(microseconds: (_frameSeconds * 1e6).round()));
    }
  }

  test('regular snoring yields snore episodes and no apnea', () {
    for (var i = 0; i < 4; i++) {
      feed(_snoreFrame(), 1.0);
      feed(_quietFrame(), 3.0);
    }
    final snores = events
        .where((e) => e.kind == AcousticDetectionKind.snore)
        .toList();
    final apneas = events.where(
      (e) => e.kind == AcousticDetectionKind.apneaPattern,
    );
    expect(snores.length, greaterThanOrEqualTo(3));
    expect(apneas, isEmpty);
    expect(snores.first.details['durationSeconds'], greaterThan(0.5));
  });

  test('long cessation after regular snoring flags an apnea pattern', () {
    for (var i = 0; i < 4; i++) {
      feed(_snoreFrame(), 1.0);
      feed(_quietFrame(), 3.0);
    }
    // Breathing stops for 15s, then a loud resuming snore/gasp.
    feed(_quietFrame(), 15.0);
    feed(_snoreFrame(), 1.0);
    feed(_quietFrame(), 1.0);

    final apneas = events
        .where((e) => e.kind == AcousticDetectionKind.apneaPattern)
        .toList();
    expect(apneas, hasLength(1));
    expect(apneas.first.details['gapSeconds'], greaterThanOrEqualTo(10));
    expect(apneas.first.details['note'], contains('not a medical diagnosis'));
  });

  test('steady high-frequency hiss is not a snore', () {
    const hiss = SpectralFrame(
      rms: 0.3,
      db: -20,
      centroidHz: 4000,
      flatness: 0.8,
      crest: 5,
      rolloffHz: 6000,
      dominantHz: 4000,
      lowBandRatio: 0.05,
      speechBandRatio: 0.4,
      totalPower: 1,
    );
    feed(hiss, 5.0);
    expect(events, isEmpty);
  });
}
