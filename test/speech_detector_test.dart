import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/services/acoustic/speech_detector.dart';
import 'package:audio_dashcam/src/services/acoustic/spectral_features.dart';
import 'package:flutter_test/flutter_test.dart';

const double _frameSeconds = 2048 / 2 / 16000; // 0.064s

SpectralFrame _voiced(double rms) => SpectralFrame(
  rms: rms,
  db: -20,
  centroidHz: 1500,
  flatness: 0.5,
  crest: 10,
  rolloffHz: 3200,
  dominantHz: 350,
  lowBandRatio: 0.15,
  speechBandRatio: 0.7, // voiced telephone band
  totalPower: 1,
);

void main() {
  late DateTime clock;

  setUp(() => clock = DateTime.utc(2026, 1, 1, 12, 0, 0));

  List<AcousticDetection> run(Iterable<SpectralFrame> frames) {
    final detector = SpeechDetector(frameSeconds: _frameSeconds);
    final out = <AcousticDetection>[];
    for (final f in frames) {
      out.addAll(detector.add(f, clock));
      clock = clock.add(Duration(microseconds: (_frameSeconds * 1e6).round()));
    }
    return out;
  }

  test('voiced band with ~5 Hz syllabic modulation is detected as speech', () {
    // ~5 Hz modulation: pulse every 3 frames (~0.19s period).
    final frames = List.generate(120, (i) => _voiced(i % 3 == 0 ? 0.5 : 0.12));
    final speech = run(
      frames,
    ).where((e) => e.kind == AcousticDetectionKind.speech);
    expect(speech, isNotEmpty);
    expect(speech.first.details['modulation'], greaterThan(0.25));
  });

  test('steady voiced tone (no syllabic modulation) is not speech', () {
    final frames = List.generate(120, (_) => _voiced(0.3));
    expect(run(frames), isEmpty);
  });

  test('music-band content (low voiced-band ratio) is not speech', () {
    final frames = List.generate(
      120,
      (i) => SpectralFrame(
        rms: i % 3 == 0 ? 0.5 : 0.12,
        db: -20,
        centroidHz: 1500,
        flatness: 0.3,
        crest: 30,
        rolloffHz: 5000,
        dominantHz: 440,
        lowBandRatio: 0.2,
        speechBandRatio: 0.2, // not dominated by the voiced band
        totalPower: 1,
      ),
    );
    expect(run(frames), isEmpty);
  });
}
