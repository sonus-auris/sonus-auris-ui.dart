import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/services/acoustic/music_detector.dart';
import 'package:audio_dashcam/src/services/acoustic/spectral_features.dart';
import 'package:flutter_test/flutter_test.dart';

const double _frameSeconds = 2048 / 2 / 16000; // 0.064s

SpectralFrame _pitched(double rms) => SpectralFrame(
  rms: rms,
  db: -20,
  centroidHz: 1200,
  flatness: 0.2, // tonal / pitched
  crest: 40,
  rolloffHz: 4000,
  dominantHz: 440,
  lowBandRatio: 0.2,
  speechBandRatio: 0.4,
  totalPower: 1,
);

void main() {
  late DateTime clock;

  setUp(() => clock = DateTime.utc(2026, 1, 1, 20, 0, 0));

  List<AcousticDetection> run(Iterable<SpectralFrame> frames) {
    final detector = MusicDetector(frameSeconds: _frameSeconds);
    final out = <AcousticDetection>[];
    for (final f in frames) {
      out.addAll(detector.add(f, clock));
      clock = clock.add(Duration(microseconds: (_frameSeconds * 1e6).round()));
    }
    return out;
  }

  test('pitched audio with a steady beat is detected as music', () {
    // Pulse the envelope every 8 frames (~0.51s, ~117 BPM).
    final frames = List.generate(200, (i) => _pitched(i % 8 < 2 ? 0.5 : 0.12));
    final events = run(frames);
    final music = events.where((e) => e.kind == AcousticDetectionKind.music);
    expect(music, isNotEmpty);
    expect(music.first.details['beatStrength'], greaterThan(0.3));
  });

  test('a steady pitched tone with no beat is not music', () {
    final frames = List.generate(200, (_) => _pitched(0.3));
    expect(run(frames), isEmpty);
  });

  test('noisy, unpitched audio is not music even if rhythmic', () {
    final frames = List.generate(
      200,
      (i) => SpectralFrame(
        rms: i % 8 < 2 ? 0.5 : 0.12,
        db: -20,
        centroidHz: 5000,
        flatness: 0.85, // noise-like, not pitched
        crest: 4,
        rolloffHz: 7000,
        dominantHz: 5000,
        lowBandRatio: 0.05,
        speechBandRatio: 0.3,
        totalPower: 1,
      ),
    );
    expect(run(frames), isEmpty);
  });
}
